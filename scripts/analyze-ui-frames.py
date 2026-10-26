#!/usr/bin/env python3
"""Offline identity join, not a claim of pixel changes or measured UI FPS.

Current captured macOS format:
 CA/1 BEGIN.arg2 = client transaction; CA/0x77 BEGIN.arg1=context,.arg3=transaction.
 D1/0x51 POINT = context,pid,client transaction,auxiliary (exact bridge discovered in raw data).
 D0/0x29 BEGIN.arg1 = frame seed (differs from installed old CLIPS arg2).
 D1/0x52 BEGIN = seed,display,surface,presentation MAT ticks.
 D1/0x52 END.arg1/2 are bitcast double host-time seconds, arg4 refresh MAT ticks.

Join exact IDs and thread-contained render intervals; never nearest timestamps.
Compositor presence/new client transactions are not independent evidence that pixels
changed, or that a particular sidebar/window generated a transaction. Cadence is
reported ONLY when a matching physical sidebar input trace passes admission.
"""
from __future__ import annotations
import argparse,bisect,collections,hashlib,json,math,re,struct,xml.etree.ElementTree as ET
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

class InvalidTrace(ValueError): pass

def need(value, message):
    if not value: raise InvalidTrace(message)

def thread_key(label):
    pid=re.search(r'pid: (\d+)\)',label or '')
    tid=re.search(r'\(0x([0-9a-fA-F]+)\)',label or '')
    need(pid and tid,'Unresolved thread identity: '+str(label))
    return int(pid[1]),int(tid[1],16)

@dataclass(frozen=True)
class Event:
    ns:int
    thread:tuple[int,int]
    code:int
    fn:int
    args:tuple[int,int,int,int]

    @classmethod
    def from_list(cls,row):
        need(len(row)==8,'Unexpected selected row shape')
        return cls(int(row[0]),thread_key(row[1]),int(row[2]),int(row[3]),tuple(map(int,row[4:])))

def xml_events(path):
    ids={}
    for _,e in ET.iterparse(path,events=['end']):
        if e.get('id'): ids[e.get('id')]=(e.text,e.get('fmt'))
        if e.tag!='row': continue
        values=[ids[x.get('ref')] if x.get('ref') else (x.text,x.get('fmt')) for x in e]
        need(len(values)==14,'Unexpected kdebug columns')
        yield Event(int(values[0][0]),thread_key(values[1][1]),int(values[8][0]),int(values[9][0]),tuple(int(x[0]) for x in values[10:14]))
        e.clear()

@dataclass(frozen=True)
class Timebase:
    epoch:int
    num:int
    den:int
    def mat_ns(self,ticks): return round(Fraction((ticks-self.epoch)*self.num,self.den))
    def seconds_ns(self,seconds): return round(seconds*1e9-FloatEpoch(self))
    def duration_ns(self,ticks): return round(Fraction(ticks*self.num,self.den))

def FloatEpoch(tb): return float(Fraction(tb.epoch*tb.num,tb.den))

def timebase(path):
    tree=ET.parse(path);rows=tree.findall('.//row')
    need(len(rows)==1,'Multiple timebase epochs require explicit segmented handling')
    base=tree.find('.//mach-timebase-info');epoch=tree.find('.//mach-absolute-time')
    need(base is not None and epoch is not None and len(base)==2,'Missing trace timebase')
    tb=Timebase(int(epoch.text),int(base[0].text),int(base[1].text))
    need(tb.num>0 and tb.den>0 and tb.epoch>0,'Invalid timebase')
    return tb

def doubles_seconds(bits): return struct.unpack('<d',struct.pack('<Q',bits))[0]

def pair(events,code,diagnostics,prefix):
    active=collections.defaultdict(list);out=[]
    for e in sorted((x for x in events if x.code==code),key=lambda x:x.ns):
        if e.fn==1: active[e.thread].append(e)
        elif e.fn==2:
            if not active[e.thread]: diagnostics[prefix+'_orphan_ends']+=1;continue
            begin=active[e.thread].pop()
            need(e.ns>=begin.ns,'Reversed interval')
            out.append((begin,e))
        else: diagnostics[prefix+'_unexpected_qualifiers']+=1
    diagnostics[prefix+'_unfinished_begins']+=sum(map(len,active.values()))
    return out

def stats_ns(values):
    if not values:return {'n':0}
    a=sorted(values)
    need(all(x>=0 and math.isfinite(x) for x in a),'Invalid timing values')
    def percentile(p):return a[max(0,math.ceil(len(a)*p)-1)]/1e6
    return {'n':len(a),'p50_ms':percentile(.50),'average_ms':sum(a)/len(a)/1e6,
            'p95_ms':percentile(.95),'p99_ms':percentile(.99),'max_ms':a[-1]/1e6}

def join(ca,d0,d1,tb,pid):
    ca=list(ca)
    diag=collections.Counter()
    client_pairs=pair((e for e in ca if e.thread[0]==pid),1,diag,'client_commit')
    by_commit=collections.defaultdict(list)
    for b,e in client_pairs: by_commit[b.args[1]].append((b,e))
    diag['client_commits']=len(client_pairs)
    contexts=collections.defaultdict(list)
    for b,e in pair((x for x in ca if x.thread[0]==pid),119,diag,'client_context_commit'):
        contexts[(b.args[0],b.args[2])].append((b,e))
    # Inventory BEGIN records independently of successful interval/presentation
    # joins. Selecting only already-presented contexts would discard the slowest
    # first response, never-presented submissions, and unfinished intervals.
    inventory=collections.defaultdict(lambda: {'submissions':[]})
    pending=collections.defaultdict(list)
    for event in sorted((e for e in ca if e.thread[0]==pid and e.code==119),key=lambda e:e.ns):
        if event.fn==1:
            submission={'commit':event.args[2],'context_begin_ns':event.ns,'context_end_ns':None}
            inventory[str(event.args[0])]['submissions'].append(submission)
            pending[event.thread].append(submission)
        elif event.fn==2 and pending[event.thread]:
            pending[event.thread].pop()['context_end_ns']=event.ns
    diag['client_context_commit_pairs']=sum(map(len,contexts.values()))
    renders=pair(d0,41,diag,'server_render')
    render_by_thread=collections.defaultdict(list)
    for b,e in renders: render_by_thread[b.thread].append((b,e))
    starts={th:[b.ns for b,e in rs] for th,rs in render_by_thread.items()}
    need(all(all(a[1].ns<=b[0].ns for a,b in zip(rs,rs[1:])) for rs in render_by_thread.values()),'Overlapping render intervals: ambiguous enclosing frame')
    presentations={};last_presentation={}
    for b,e in pair(d1,82,diag,'display_presentation'):
        seed,display,surface,mat=b.args
        key=(seed,display)
        need(key not in presentations,'Duplicate frame-seed/display presentation')
        earliest,requested=map(doubles_seconds,e.args[:2])
        # These END seconds are auxiliary eligibility/request timestamps, not
        # the actual presentation clock used for joins or cadence. A captured
        # valid frame can retain an earliest value from before recording began.
        need(all(math.isfinite(x) for x in (earliest,requested)),
             'Nonfinite D1 END auxiliary seconds')
        refresh=tb.duration_ns(e.args[3]);need(1_000_000<=refresh<=100_000_000,'Invalid refresh MAT duration')
        pres=tb.mat_ns(mat)
        if display in last_presentation:
            old_seed,old_time=last_presentation[display]
            need(seed>old_seed and pres>old_time,'Nonmonotonic display frame seeds/presentation clock')
        last_presentation[display]=(seed,pres)
        need(abs(pres-b.ns)<1_000_000_000,'Presentation MAT not on this trace epoch')
        earliest_ns,requested_ns=tb.seconds_ns(earliest),tb.seconds_ns(requested)
        diag['presentation_auxiliary_earliest_before_trace_epoch']+=int(earliest_ns<0)
        diag['maximum_auxiliary_earliest_to_presentation_ns']=max(
            diag['maximum_auxiliary_earliest_to_presentation_ns'],pres-earliest_ns)
        diag['maximum_auxiliary_requested_to_presentation_ns']=max(
            diag['maximum_auxiliary_requested_to_presentation_ns'],pres-requested_ns)
        presentations[key]={'seed':seed,'display':display,'surface':surface,'presentation_ns':pres,
            'earliest_ns':earliest_ns,'requested_ns':requested_ns,
            'refresh_ns':refresh,'notification_ns':b.ns}
    diag['server_render_pairs']=len(renders);diag['display_presentations']=len(presentations)
    last={};updates=collections.defaultdict(list);compositions=collections.Counter();seen_updates=set()
    for point in sorted((e for e in d1 if e.code==81),key=lambda e:e.ns):
        need(point.fn==0,'D1/0x51 qualifier changed')
        context,owner,commit,auxiliary=point.args
        if owner!=pid:continue
        if auxiliary:diag['target_context_composites_with_auxiliary_value']+=1
        diag['target_context_composites']+=1
        rs=render_by_thread.get(point.thread,[]);pos=bisect.bisect_right(starts.get(point.thread,[]),point.ns)-1
        if pos<0 or not rs[pos][0].ns<=point.ns<=rs[pos][1].ns:
            diag['context_composite_without_enclosing_render']+=1;continue
        b,end=rs[pos];key=(b.args[0],b.args[3])
        if key not in presentations:diag['render_without_presentation']+=1;continue
        frame=presentations[key]
        if frame['presentation_ns']<end.ns:
            diag['presentation_before_render_end']+=1;continue
        compositions[context]+=1
        old=last.get(context)
        if old is None:
            last[context]=commit;diag['first_observation_context_baselines']+=1
            # A first-seen tuple can be admitted only if its exact client submission is captured.
        elif commit==old:
            diag['repeated_context_commit_composites']+=1;continue
        elif commit<old:
            diag['nonmonotonic_context_commit']+=1;continue
        else:last[context]=commit
        tuple_id=(context,commit)
        if tuple_id in seen_updates:diag['duplicate_update_points']+=1;continue
        seen_updates.add(tuple_id)
        candidates=[(cb,ce) for cb,ce in contexts.get(tuple_id,[]) if ce.ns<=point.ns]
        if not candidates:diag['new_tuple_without_captured_client_context_commit']+=1;continue
        commits=by_commit.get(commit,[])
        if len(commits)!=1:
            diag['new_tuple_without_unique_client_transaction']+=1;continue
        cb,ce=commits[0]
        context_begin,context_end=max(candidates,key=lambda x:x[1].ns)
        if cb.ns>context_begin.ns or ce.ns>frame['presentation_ns']:
            diag['client_transaction_order_unvalidated']+=1;continue
        updates[key].append({'context':context,'commit':commit,'pid':pid,'client_thread':cb.thread[1],
            'client_begin_ns':cb.ns,'client_end_ns':ce.ns,'context_begin_ns':context_begin.ns,
            'context_end_ns':context_end.ns,'server_composite_ns':point.ns,
            'render_begin_ns':b.ns,'render_end_ns':end.ns,**frame})
    need(diag['nonmonotonic_context_commit']==0,'Context commit IDs moved backwards: current identity semantics unvalidated')
    frames=[];first_commit={}
    for key,rows in sorted(updates.items(),key=lambda kv:presentations[kv[0]]['presentation_ns']):
        frame=presentations[key]
        frames.append({**frame,'updates':rows})
        for row in rows:
            cid=(row['client_thread'],row['commit'])
            first_commit.setdefault(cid,row)
    per_context=collections.defaultdict(list)
    for f in frames:
        for row in f['updates']:per_context[row['context']].append(row)
    diag['new_context_updates_presented']=sum(len(f['updates']) for f in frames)
    diag['presentation_frames_with_exact_new_client_update']=len(frames)
    diag['unique_client_commits_presented']=len(first_commit)
    diag['client_commits_without_exact_observed_presentation']=len(client_pairs)-len(first_commit)
    commit_begin=[r['presentation_ns']-r['client_begin_ns'] for r in first_commit.values()]
    commit_end=[r['presentation_ns']-r['client_end_ns'] for r in first_commit.values()]
    result={'classification':'EXACT_CONTEXT_PRESENTATION_JOIN_WITHOUT_VERIFIED_INTERACTION','target_pid':pid,
        'timebase':{'epoch':tb.epoch,'numerator':tb.num,'denominator':tb.den},'diagnostics':dict(diag),
        'client_commit_work':stats_ns([e.ns-b.ns for b,e in client_pairs]),
        'unique_client_commit_begin_to_first_presentation':stats_ns(commit_begin),
        'unique_client_commit_end_to_first_presentation':stats_ns(commit_end),
        'per_context':{str(ctx):{'all_compositions':compositions[ctx],'new_updates_presented':len(rows),
            'distinct_commits':len({r['commit'] for r in rows})} for ctx,rows in per_context.items()},
        'target_context_inventory':dict(inventory),'presentation_cadence':None,
        'limitations':['New transaction/context identifiers are not proof of changed pixels.',
            'PID attribution alone does not identify the active window/sidebar among multiple contexts.',
            'Client transactions coalesce; repeated composites are excluded; commits never observed presenting are censored.',
            'A matching admitted physical sidebar input trace is required for a cadence conclusion.',
            'D1/0x51 bridge is empirically exact in this capture; installed old Apple CLIPS does not document this current tracepoint.']}
    return result,frames

def add_scroll_trace(result,frames,path,tb,coverage,provenance,expected_rows=100):
    """Admit recorded physical demand; retain unexplained input/presentation gaps.

    Never split on elapsed time: delayed delivery and event coalescing can make
    a main-thread hitch look like an input pause. Only explicit gesture end →
    new physical begin, cancellation, or momentum end closes a demand segment.
    """
    need(provenance is not None,'--scroll-trace requires recording provenance')
    trace_bytes=path.read_bytes()
    value=json.loads(trace_bytes)
    need(value.get('pid')==result['target_pid'],'Sidebar input trace PID differs')
    need(value.get('dropped')==0,'Sidebar input trace dropped records')
    need((value.get('timebaseNumer'),value.get('timebaseDenom'))==(tb.num,tb.den),
         'Sidebar input and raw recording timebases differ')
    records=value.get('records',[])
    need(records and records[0].get('kind')==3 and records[-1].get('kind')==4,
         'Sidebar input trace lacks complete start/end markers')
    need(sum(r.get('kind')==3 for r in records)==1 and sum(r.get('kind')==4 for r in records)==1,
         'Sidebar input trace has ambiguous observation boundaries')
    clock_offsets=[]
    previous=None
    for record in records:
        ticks,uptime=record.get('ticks'),record.get('uptime')
        need(type(ticks)is int and ticks>0 and isinstance(uptime,(int,float))
             and math.isfinite(uptime) and uptime>=0,'Invalid sidebar input clock')
        need(previous is None or ticks>=previous,'Sidebar input clock moved backwards')
        previous=ticks
        record['ns']=tb.mat_ns(ticks)
        clock_offsets.append(round(uptime*1e9)-tb.duration_ns(ticks))
    spread=max(clock_offsets)-min(clock_offsets)
    need(spread<=2_000_000,'Sidebar paired uptime/MAT anchors disagree by more than 2 ms')
    inputs=[r for r in records if r['kind']==1]
    need(inputs,'No precise physical sidebar input was recorded')
    for record in inputs:
        event_time=record.get('eventTime')
        need(isinstance(event_time,(int,float)) and math.isfinite(event_time)
             and 0<=event_time<=record['uptime'],'Invalid physical event timestamp')
        record['queue_ns']=round((record['uptime']-event_time)*1e9)
        record['event_ns']=record['ns']-record['queue_ns']
    need(all(a['event_ns']<=b['event_ns'] for a,b in zip(inputs,inputs[1:])),
         'Physical event timestamps moved backwards')
    changing=[r for r in inputs if math.isfinite(r.get('dy',math.nan)) and r['dy']!=0]
    need(changing,'No vertical scroll deltas were recorded')
    lo,hi=changing[0]['event_ns'],changing[-1]['ns']
    need(lo>=0 and lo<=hi,'Physical input onset predates this raw recording')
    need(set(coverage)=={'client','render','display'},'Missing raw-stream coverage evidence')
    for name,bounds in coverage.items():
        need(bounds is not None and bounds[0]<=lo and bounds[1]>=hi,
             name+' raw stream does not cover complete physical demand')
    observed=[r for r in records if lo<=r['ns']<=hi]
    need(all(r.get('key') is True and r.get('active') is True and r.get('visible') is True for r in observed),
         'Sidebar lost sampled key/active/visible state during physical demand')
    need(all(r.get('hit') is True for r in inputs if lo<=r['event_ns'] and r['ns']<=hi),
         'Physical input left the sidebar viewport')
    row_samples=[r for r in observed if r['kind']==5]
    need(all(type(r.get('rowCount'))is int and r['rowCount']>=0 for r in row_samples),
         'Invalid populated section row count')
    counts=sorted({r['rowCount'] for r in row_samples})
    need(expected_rows in counts,'No expected populated-section row count was observed')
    need(set(counts)<={0,expected_rows},'Populated section row count changed during physical demand')
    origin=records[0]['y']
    movement=[r for r in observed if r['kind']==2 and r['y']!=origin]
    need(movement,'No actual sidebar clip movement was recorded')
    groups=[];current=[];pending_end=False
    for record in inputs:
        phase,momentum=record.get('phase',0),record.get('momentum',0)
        # NSEventPhase: began1, stationary2, changed4, ended8, cancelled16.
        if current and pending_end and phase&1 and not momentum:
            groups.append(current);current=[];pending_end=False
        current.append(record)
        if momentum&24 or phase&16:
            groups.append(current);current=[];pending_end=False
        elif phase&8 and not momentum:pending_end=True
        elif momentum:pending_end=False
    if current:groups.append(current)
    groups=[[r for r in group if r['dy']!=0] for group in groups]
    groups=[group for group in groups if group]
    inventory=result['target_context_inventory']
    contexts=sorted({int(context) for context in inventory} |
                    {u['context'] for f in frames for u in f['updates']})
    analyses={};all_complete=True
    raw_end=min(bounds[1] for bounds in coverage.values())
    for context in contexts:
        context_frames=sorted((f for f in frames if any(u['context']==context for u in f['updates'])),
                              key=lambda f:f['presentation_ns'])
        need(len({f['display'] for f in context_frames})<=1,
             'One context crosses display clocks during scroll')
        submissions=inventory.get(str(context),{}).get('submissions',[])
        unfinished=[s for s in submissions if s['context_end_ns'] is None]
        presented_commits={u['commit'] for f in context_frames for u in f['updates']
                           if u['context']==context and 'commit' in u}
        unobserved=[s for s in submissions if s['commit'] not in presented_commits]
        # Missing submissions may have coalesced, or may never have presented.
        # Retain the uncertainty instead of silently treating them as fast.
        context_complete=not(unfinished or unobserved)
        intervals=set();segments=[];onsets=[];censored=[]
        for index,group in enumerate(groups):
            first,last=group[0],group[-1]
            # This is a post-receipt transaction proxy, not causal input→pixel attribution.
            first_response=next((f for f in context_frames if f['presentation_ns']>=first['ns']
                and any(u['context']==context and u['client_begin_ns']>=first['ns'] for u in f['updates'])),None)
            last_response=next((f for f in context_frames if f['presentation_ns']>=last['ns']
                and any(u['context']==context and u['context_end_ns']>=last['ns'] for u in f['updates'])),None)
            if first_response is None or last_response is None:
                context_complete=False
                censored.append({'segment':index,'first_receipt_ns':first['ns'],'last_receipt_ns':last['ns'],
                    'raw_observation_end_ns':raw_end,'first_response_missing':first_response is None,
                    'last_response_missing':last_response is None,
                    'first_event_response_lower_bound_ms':(raw_end-first['event_ns'])/1e6 if first_response is None else None,
                    'last_event_response_lower_bound_ms':(raw_end-last['event_ns'])/1e6 if last_response is None else None})
                continue
            start,end=first_response['presentation_ns'],last_response['presentation_ns']
            need(start<=end<=raw_end,'Post-input presentation is outside complete raw coverage')
            next_start=groups[index+1][0]['event_ns'] if index+1<len(groups) else None
            if next_start is not None and (start>=next_start or end>=next_start):
                context_complete=False
                censored.append({'segment':index,'reason':'Delayed response overlaps the next gesture; independent onset attribution is ambiguous'})
                continue
            selected=sorted({f['presentation_ns'] for f in context_frames if start<=f['presentation_ns']<=end})
            intervals.update(zip(selected,selected[1:]))
            onsets.append(start-first['event_ns'])
            segments.append({'physical_start_ns':first['event_ns'],'first_receipt_ns':first['ns'],
                'last_receipt_ns':last['ns'],'first_new_context_presentation_ns':start,
                'last_post_receipt_context_presentation_ns':end,'presentation_count':len(selected)})
        all_complete=all_complete and context_complete
        analyses[str(context)]={'attribution':'unknown; may be static or unrelated to the sidebar',
            'complete_uncensored':context_complete,
            'captured_submissions':len(submissions),'unfinished_submissions':len(unfinished),
            'submissions_without_exact_observed_presentation':len(unobserved),
            'submission_uncertainty':'Unobserved submissions may coalesce or remain unpresented; neither is classified as a fast response.',
            'cadence_intervals':stats_ns([b-a for a,b in intervals]),
            'event_to_first_post_receipt_context_presentation':stats_ns(onsets),
            'longest_intervals':[{'start_ns':a,'end_ns':b,'duration_ms':(b-a)/1e6}
                for a,b in sorted(intervals,key=lambda pair:pair[1]-pair[0],reverse=True)[:20]],
            'segments':segments,'censored_segments':censored}
    first_bounds=next((r for r in movement if r['ns']>=changing[0]['ns']),None)
    result['physical_scroll']={'source':str(path),'source_sha256':hashlib.sha256(trace_bytes).hexdigest(),
        'row_counts_observed':counts,'expected_section_rows':expected_rows,
        'sidebar_observation_reason':value.get('reason'),'sidebar_record_count':len(records),
        'vertical_delta_count':len(changing),
        'first_physical_delta_ns':lo,'last_delta_receipt_ns':hi,'paired_clock_anchor_spread_ns':spread,
        'input_queue_latency':stats_ns([r['queue_ns'] for r in changing]),
        'first_event_to_bounds_ms':None if first_bounds is None else (first_bounds['ns']-lo)/1e6,
        'first_receipt_to_bounds_ms':None if first_bounds is None else (first_bounds['ns']-changing[0]['ns'])/1e6,
        'explicit_gesture_segments':len(groups),'per_context':analyses,
        'complete_uncensored_contexts':bool(contexts) and all_complete,
        'no_presented_context_onset_lower_bound_ms':(raw_end-lo)/1e6 if not frames else None,
        'raw_stream_coverage_ns':coverage,'sidebar_records_dropped':0,
        'limits':['Cadence is exact new target-client context presentation intervals, not measured pixel-change FPS.',
            'Contexts are reported separately; process identity alone cannot identify the sidebar window.',
            'Onset uses the first new transaction begun after input receipt; causality and hardware touch-to-pixel latency are not established.',
            'Only explicit gesture boundaries exclude idle. Unexplained gaps, including coalesced-event or main-thread stalls, remain.',
            'Foreground/viewport checks are sampled, not continuous window-focus monitoring.',
            'Row count verifies populated geometry, not real website URLs; retain independent real-tab evidence.',
            'Sidebar drop count is checked; raw-stream extents and join diagnostics cannot prove absence of silent kernel event loss.']}
    result['classification']='PHYSICAL_SIDEBAR_DEMAND_CONTEXT_PRESENTATIONS' if contexts and all_complete else 'PHYSICAL_SCROLL_WITH_CENSORED_OR_MISSING_CONTEXT_PRESENTATIONS'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True,help='Directory exported by record-ui-frames.py')
    parser.add_argument('--output',type=Path,required=True,help='New private analysis directory')
    parser.add_argument('--pid',type=int,help='Required when recording.json is unavailable')
    parser.add_argument('--scroll-trace',type=Path,help='SidebarScrollTrace JSON from this exact app launch')
    parser.add_argument('--expected-sidebar-rows',type=int,default=100)
    args=parser.parse_args()
    p=args.run.resolve(strict=True)
    provenance_path=p/'recording.json'
    provenance=json.loads(provenance_path.read_text()) if provenance_path.exists() else None
    recorded_pid=provenance['target']['pid'] if provenance else None
    pid=args.pid if args.pid is not None else recorded_pid
    need(type(pid)is int and pid>0,'Specify the recorded target PID')
    need(recorded_pid is None or recorded_pid==pid,'PID differs from recording provenance')
    if provenance:
        need(provenance.get('exitCode')==0 and provenance.get('recorderExited') is True
             and provenance.get('tracingStartedConfirmed') is True
             and provenance.get('fullRecording') is True,'Recording was not fully saved/admitted')
        need(provenance.get('targetAfter')==provenance['target'],'Target app launch changed during recording')
    raw={name:list(xml_events(p/(name+'.xml'))) for name in ('client','render','display')}
    coverage={name:(min(e.ns for e in events),max(e.ns for e in events)) if events else None
              for name,events in raw.items()}
    ca=[e for e in raw['client'] if e.thread[0]==pid and e.code in (1,119)]
    d0=[e for e in raw['render'] if e.code==41]
    d1=[e for e in raw['display'] if e.code==82 or (e.code==81 and e.args[1]==pid)]
    tb=timebase(p/'clock.xml')
    result,frames=join(ca,d0,d1,tb,pid)
    if args.scroll_trace:add_scroll_trace(result,frames,args.scroll_trace,tb,coverage,provenance,args.expected_sidebar_rows)
    output=args.output.resolve()
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    (output/'presentation-joins.json').write_text(json.dumps(frames,indent=2)+'\n')
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
