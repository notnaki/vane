#!/usr/bin/env python3
"""Hosted605c adaptation of reviewed local controllers; no test implementation changes."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
from datetime import datetime,timezone
import hashlib,importlib.util,json,math,os,re,subprocess,tempfile,time
ROOT=Path.cwd().resolve();OUT=Path(os.environ['VANE_DIAGNOSTIC_DIR']);STATUS=OUT/'runtime-status.json'
HELPERS=Path(__file__).resolve().parent;sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
PACKET=Path(os.environ['VANE_BUILD_MANIFEST']);EXPECTED=os.environ['VANE_BUILD_MANIFEST_SHA'];assert sha(PACKET)==EXPECTED
runtime=json.loads(PACKET.read_text());data=json.loads((HELPERS/'f17-spell605-slots.json').read_text());mode=os.environ['VANE_JOB_KIND'];assert mode in ('controls','observation')
plan={'head':os.environ['GITHUB_SHA'],'workspace':str(ROOT),'source':{'path':str(ROOT/'Tests/VaneTests/PasswordAutofillTests.swift')},'bundle':{'path':str(ROOT/runtime['test_bundle']),'binary':str(ROOT/runtime['test_binary'])},'cohorts':data['cohorts'],'execution':{'clear_environment':data['clear_environment'],'environment':{'VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT':'180'}}}
assert runtime['head']==plan['head'] and runtime['source']==data['source']==os.environ['VANE_F17_NATIVE_WRITER_SOURCE']
assert re.fullmatch(r'[0-9a-f]{40}',data['source'])
plan['execution']['environment'].update(VANE_F17_PRIVATE_TRACE_V1='1',VANE_F17_TRACE_SOURCE_HEAD=plan['head'])
STATUS.write_text(json.dumps({'mode':mode,'source':data['source'],'head':plan['head'],'current_runtime_only_not_historical':True,'F17_fixed':False},indent=2)+'\n')
def update(**items):
    state=json.loads(STATUS.read_text());state.update(items);state['updated_at']=datetime.now(timezone.utc).isoformat();STATUS.write_text(json.dumps(state,indent=2)+'\n')
def integrity():
    assert sha(PACKET)==EXPECTED
    assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()==plan['head']
    assert subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],text=True)==''
    assert not (ROOT/'.build').is_symlink() and (ROOT/'.build').resolve()==ROOT/'.build'
    assert sha(os.environ['VANE_RUNTIME_ARCHIVE'])==runtime['archive_sha256']==os.environ['VANE_RUNTIME_ARCHIVE_SHA']
    for file,digest in {**runtime['source_pins'],**runtime['native_writer_source_pins']}.items():assert sha(ROOT/file)==digest,file
    for file,digest in json.loads(os.environ['VANE_DIAGNOSTIC_SOURCE_PINS']).items():assert sha(ROOT/file)==digest,file
    for file,digest in runtime['files'].items():
        live=ROOT/file;assert live.is_file() and not live.is_symlink() and live.resolve()==live and sha(live)==digest,file
        assert live.stat().st_mode & 0o7777==runtime['file_modes'][file],file
    for file,target in runtime['links'].items():
        live=ROOT/file;assert live.is_symlink() and os.readlink(live)==target and live.resolve().is_relative_to(ROOT/'.build'),file
    for component in runtime['components']:
        live=ROOT/component
        actual={str(p.relative_to(ROOT)) for p in live.rglob('*') if p.is_file() or p.is_symlink()} if live.is_dir() else {component}
        expected={p for p in runtime['files'] if p==component or p.startswith(component+'/')}
        expected|={p for p in runtime['links'] if p==component or p.startswith(component+'/')}
        assert actual==expected,'Runtime component leaf inventory changed '+component
    return {'head':plan['head'],'source':data['source'],'binary_sha256':sha(ROOT/runtime['test_binary']),'all_runtime_code_resource_files_match':True,'description_path':str(ROOT/runtime['description']),'description_sha256':sha(ROOT/runtime['description']),'metadata_drift_permitted':False,'clean_tracked_sources':True,'current_runtime_only_not_historical':True}
def checkpoint(stage):
    description=ROOT/runtime['description']
    if description.is_file():(OUT/('description.'+stage+'.json')).write_bytes(description.read_bytes())
    snapshot=integrity();(OUT/('integrity.'+stage+'.json')).write_text(json.dumps(snapshot,indent=2)+'\n')
    return snapshot
checkpoint('before-discovery')
clean_env=dict(os.environ)
for key in data['clear_environment']:clean_env.pop(key,None)
with (OUT/'inventory.raw.txt').open('xb') as stdout,(OUT/'inventory.stderr.txt').open('xb') as stderr:
    listed=subprocess.run(['swift','test','--build-system','native','list','--skip-build'],env=clean_env,stdout=stdout,stderr=stderr)
checkpoint('after-discovery');assert listed.returncode==0
inventory=[line.strip() for line in (OUT/'inventory.raw.txt').read_text().splitlines() if line.strip() and line.strip()!='Native test host bootstrap: beforeAppKit=true, configured=true']
assert len(inventory)==len(set(inventory))==data['inventory']['count']
assert all(re.fullmatch(r'[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/[^\s/]+',line) for line in inventory)
canonical='\n'.join(sorted(inventory));assert hashlib.sha256(canonical.encode()).hexdigest()==data['inventory']['sha256'];(OUT/'inventory.canonical.txt').write_text(canonical)
attempt_slots=data['controls'] if mode=='controls' else [dict(data['observation'],attempt=int(os.environ['VANE_OBSERVATION_INDEX']))]
for slot in attempt_slots:
    ids=slot['selected'];assert all(case in inventory for case in ids)
    pattern='^(?:'+'|'.join(re.escape(case) for case in ids)+')$'
    assert sorted(case for case in inventory if re.search(pattern,case))==sorted(ids)
    slot.update(argv=['python3','scripts/run-native-tests.py','--build-system','native','--skip-build','--jobs','1','--filter',pattern],raw_log=str(OUT/(('control-' if mode=='controls' else 'original18-')+str(slot['attempt'])+'.log')),result_json=str(OUT/(('control-' if mode=='controls' else 'original18-')+str(slot['attempt'])+'.result.json')))
schedule=[{'attempt':slot['attempt'],'cohort':slot['cohort'],'status':'NOT RUN'} for slot in attempt_slots];(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n')
def private_plan(directory,selected,expected):
    case=lambda value:'-['+value.split('/')[0]+' '+value.split('/')[1]+']'
    path=directory/'private-plan.json';path.write_text(json.dumps({'allowed_cases':[case(c) for c in selected],'expected_files':[[case(c),channel] for c,channel in expected]},indent=2)+'\n');path.chmod(0o600);return path

def private_payloads(proof,audit,selected):
    from f17_private_file_trace import validate_payload,case_key
    capture=proof.get('private_exports_capture',{})
    assert proof.get('private_capture_complete') is True and capture.get('capture_complete') is True
    assert proof.get('completed_primary_handoff_calls')==1 and proof.get('original_check_hosts_completed_before_capture') is True
    assert capture['sourceRevision']==plan['head'] and capture['validation_errors']==[]
    channels={'spell':[],'continuation':[]}
    for entry in sorted(capture['exports'],key=lambda e:(selected.index(case_key(e['header']['case'])),e['header']['channel'])):
        assert entry['ownership_verified'] and entry['payload_complete'] and entry['removed']
        raw=(audit/'private-exports'/entry['archive']).read_bytes();assert hashlib.sha256(raw).hexdigest()==entry['sha256']
        body=validate_payload(raw,entry['header']);assert hashlib.sha256(body).hexdigest()==entry['body_sha256']
        channels[entry['header']['channel']].append(body)
    return {channel:b''.join(parts) for channel,parts in channels.items()}

smoke_env=dict(clean_env,**plan['execution']['environment']);smoke_env.update(VANE_APPKIT_LOOP_SMOKE='1',VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT='90')
smoke_audit=OUT/'smoke-audit';smoke_audit.mkdir(mode=0o700,exist_ok=False);smoke_plan=private_plan(smoke_audit,['VaneTests.NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops'],[])
with (OUT/'smoke.log').open('xb') as stream:
    smoke=subprocess.run(['python3',str(HELPERS/'f17_canonical_boundary_audit.py'),'--audit-dir',str(smoke_audit),'--private-plan',str(smoke_plan),'--','--build-system','native','--skip-build','--jobs','1','--filter','^VaneTests[.]NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops$'],env=smoke_env,stdout=stream,stderr=subprocess.STDOUT)
checkpoint('after-smoke');smoke_text=(OUT/'smoke.log').read_text();assert smoke.returncode==0 and 'AppKit loop smoke: delayedHeartbeat=true, completed=true' in smoke_text and 'Native suite primary status=0; cleanup status=0' in smoke_text
smoke_proof=json.loads((smoke_audit/'boundary-proof.json').read_text())
assert smoke_proof['proof_complete'] is True and smoke_proof['canonical_status']==0 and smoke_proof['qualification_exit']==0
assert private_payloads(smoke_proof,smoke_audit,['VaneTests.NativeApplicationLoopSmokeTests/testOwnedLoopAdmitsAsyncWorkAndStops'])=={'spell':b'','continuation':b''}
assert smoke_proof['protocol']=='native-self-kernel-and-canonical-boundary-v1' and smoke_proof['external_initial_live_observation_performed'] is False
assert not re.search(r'^\*\*\* Signal [0-9]+:',smoke_text,re.M)
assert all(not Path(slot['raw_log']).exists() and not Path(slot['result_json']).exists() for slot in attempt_slots)
sys.path.insert(0,str(HELPERS));from spell_trace_validation import validate,validate_original18
all_results=[]
for slot in attempt_slots:
 n=slot['attempt'];entry=next(x for x in schedule if x['attempt']==n);entry['status']='RUNNING';(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n');log=Path(slot['raw_log']);result_path=Path(slot['result_json']);audit=OUT/f'attempt-{n}-audit';audit.mkdir(mode=0o700,exist_ok=False);before=integrity();(audit/'description.before.json').write_bytes(Path(before['description_path']).read_bytes())
 environment=dict(os.environ)
 for key in data['clear_environment']:environment.pop(key,None)
 environment.update(plan['execution']['environment']);environment.update(slot['environment'])
 for key in slot['unset_environment']:assert key not in environment
 trace_plan=private_plan(audit,slot['selected'],slot['private_exports'])
 command=['python3',str(HELPERS/'f17_canonical_boundary_audit.py'),'--audit-dir',str(audit),'--private-plan',str(trace_plan),'--',*slot['argv'][2:]]
 with log.open('xb') as stream:completed=subprocess.run(command,env=environment,stdout=stream,stderr=subprocess.STDOUT,check=False)
 code=completed.returncode
 raw_bytes=log.read_bytes();warning=b"warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.\n";normalized=raw_bytes.replace(warning,b'');normalized_log=log.with_suffix('.normalized.log');assert not normalized_log.exists();normalized_log.write_bytes(normalized);text=normalized.decode('utf-8',errors='replace');errors=[]
 raw_text=text;proof_path=audit/'boundary-proof.json';proof=json.loads(proof_path.read_text()) if proof_path.exists() else {'proof_complete':False,'audit_errors':['Boundary proof missing'],'canonical_status':None}
 try:channels=private_payloads(proof,audit,slot['selected'])
 except Exception as error:errors.append('authoritative private file payloads '+repr(error));channels={'spell':b'','continuation':b''}
 continuation_log=log.with_suffix('.private-continuation.log');spell_log=log.with_suffix('.private-spell.log');continuation_log.write_bytes(channels['continuation']);spell_log.write_bytes(channels['spell']);trace_text=channels['continuation'].decode('utf-8',errors='replace');spell_text=channels['spell'].decode('utf-8',errors='replace')
 try:
  (audit/'description.after.json').write_bytes(Path(before['description_path']).read_bytes());after=integrity()
 except Exception as error:after={'error':str(error)};errors.append('postrun integrity '+str(error))
 starts=[a+'/'+b for a,b in re.findall(r"Test Case '-\[([^ ]+) ([^ ]+)\]' started\.",text)];finishes=re.findall(r"Test Case '-\[([^ ]+) ([^ ]+)\]' (passed|failed|skipped) \(",text);completed=[a+'/'+b for a,b,state in finishes];outcomes={}
 for a,b,state in finishes:outcomes.setdefault(a+'/'+b,[]).append(state)
 ids=slot['selected'];retirement='VaneTests.NativeFixtureRetirementTests/testRetireManifest';expected=ids+[retirement]
 if starts!=expected:errors.append('case start list/order/duplicates differ from frozen cohort plusfreshretirement')
 if completed!=expected:errors.append('case completion list/order/duplicates differ from frozen cohort plusfreshretirement')
 for case in expected:
  if outcomes.get(case)!=['passed']:errors.append('case not passed once '+case)
 assertions=list(dict.fromkeys(line for stream in (raw_text,text) for line in stream.splitlines() if re.search(r'error: -\[',line)))
 if assertions:errors.append('native assertion records present')
 summary=re.findall(r'Native suite primary status=(-?\d+); cleanup status=(-?\d+)',text);primary,cleanup=map(int,summary[0]) if len(summary)==1 else (-999,-999)
 if (primary,cleanup,code)!=(0,0,0):errors.append('primary/cleanup/wrapper not0/0/0')
 if any(re.search(r'^\*\*\* Signal|^Fatal error:|^UNVERIFIED native fixture retirement|^NATIVE PRIMARY TIMEOUT',stream,re.I|re.M) for stream in (raw_text,text)):errors.append('fatal/timeout/unverified marker')
 trace=[];samples={};context=[]
 for match in re.finditer(r'F17_CONTINUATION case=("(?:[^"\\]|\\.)*") phase=(\S+) uptime=([\d.]+) ([^\n]*)',trace_text):
  try:case_name=json.loads(match[1])
  except Exception:errors.append('Malformed diagnostic case tag');continue
  alias=re.fullmatch(r'-\[(?:VaneTests\.)?PasswordAutofillTests (\w+)\]',case_name)
  if alias:case_name='-[VaneTests.PasswordAutofillTests '+alias[1]+']'
  trace.append({'case':case_name,'phase':match[2],'uptime':float(match[3]),'state':match[4]})
 if 'phase=diagnostic-overflow' in trace_text:errors.append('Diagnostic overflow; attribution incomplete')
 if plan['cohorts'][slot['cohort']]['trace_cases'] and not trace:errors.append('No case-tagged diagnostic records')
 for record in trace:
  if not math.isfinite(record['uptime']):errors.append('Nonfinite diagnostic time')
  name=record['case'];match=re.fullmatch(r'-\[VaneTests\.PasswordAutofillTests (\w+)\]',name)
  if not match or 'VaneTests.PasswordAutofillTests/'+match[1] not in ids:errors.append('Foreign or malformed diagnostic case '+name)
 for method, requirements in plan['cohorts'][slot['cohort']]['trace_cases'].items():
  paths=requirements['paths'];name='-[VaneTests.PasswordAutofillTests '+method+']';rows=[r for r in trace if r['case']==name];phases={}
  for row in rows:phases[row['phase']]=phases.get(row['phase'],0)+1
  samples[method]=phases
  if not errors:
   for phase in ['sdk-request-document-before-guard','sdk-request-returned','owner-sdk-request-before-guard']:
    if phases.get(phase,0)!=len(paths):errors.append('Missing/duplicate request phase '+method+' '+phase)
   if phases.get('username-processing-admitted',0)!=requirements['username_acks']:errors.append('Missing/duplicate processed-ACK admission '+method)
   for phase in ['sdk-request-document-before-guard','sdk-request-returned']:
    for path in paths:
     if sum(r['phase']==phase and r['state'].startswith('path='+path+' ') for r in rows)!=1:errors.append('Missing/duplicate path phase '+method+' '+path+' '+phase)
   if requirements.get('requires_caught_premature_admission'):
    if any(r['state'].startswith('path=password ') for r in rows):errors.append('DOM-only caught-control navigated to password')
    tag='VaneTests.PasswordAutofillTests '+method
    block=re.search(re.escape("Test Case '-["+tag+"]' started.")+r'(.*?)'+re.escape("Test Case '-["+tag+"]' passed ("),text,re.S)
    if block is None or 'PrematureFillAdmission()' not in block[1]:errors.append('Missing actual caught premature-admission counterexample '+method)
 context=[r for r in trace if r['phase'].startswith('owner-')]
 spell_trace=validate(spell_text+'\n'+trace_text,slot,control_context=raw_text,private_control_text=trace_text) if mode=='controls' else validate_original18(raw_text,slot,spell_text=spell_text,spell_scope_verified=proof.get('private_capture_complete',False),continuation_text=trace_text);errors.extend(spell_trace['validation_errors'])
 spell_trace['private_exports_capture']=str(audit/'private-exports-capture.json');spell_trace['derived_channels']={'continuation':str(continuation_log),'spell':str(spell_log)}
 proof_path=audit/'boundary-proof.json'
 proof=json.loads(proof_path.read_text()) if proof_path.exists() else {'proof_complete':False,'audit_errors':['Boundary proof missing'],'canonical_status':None}
 if proof.get('proof_complete') is not True:errors.append('Canonical boundary proof incomplete: '+repr(proof.get('audit_errors')))
 if proof.get('canonical_status')!=primary:errors.append('Canonical boundary status and native summary mismatch')
 if proof.get('external_initial_live_observation_performed') is not False:errors.append('New proof contract must not imply external initial-live capture')
 result={'attempt':n,'source':data['source'],'diagnostic_head':plan['head'],'compiled_head':runtime['head'],'diagnostic_driver_exit':code,'canonical_wrapper_status':proof.get('canonical_status'),'primary':primary,'cleanup':cleanup,'case_starts':starts,'case_completions':completed,'outcomes':outcomes,'assertion_records':assertions,'validation_errors':errors,'spell_trace':spell_trace,'trace':trace,'diagnostic_phase_summary':samples,'owner_records':context,'boundary_proof':str(proof_path),'boundary_proof_complete':proof.get('proof_complete',False),'ownership_protocol':'native-self-kernel-and-canonical-boundary-v1','external_initial_live_observation_performed':False,'pre_hashes':before,'post_hashes':after,'log_sha256':sha(log),'normalized_log_sha256':sha(normalized_log),'exact_warning_removals':raw_bytes.count(warning),'old_failed_run_unchanged':True,'F17_fixed':False};result_path.write_text(json.dumps(result,indent=2)+'\n');entry.update(status='FAILED/INCONCLUSIVE' if errors else 'PASSED',primary=primary,cleanup=cleanup);(OUT/'execution-plan.json').write_text(json.dumps(schedule,indent=2)+'\n');all_results.append({'attempt':n,'result':str(result_path),'primary':primary,'cleanup':cleanup,'validation_errors':errors,'boundary_proof_complete':proof.get('proof_complete',False)});(OUT/'attempt-summary.json').write_text(json.dumps(all_results,indent=2)+'\n');print(json.dumps(all_results[-1],indent=2),flush=True)
 if errors:break
complete=len(all_results)==len(attempt_slots) and all(not x['validation_errors'] for x in all_results)
(OUT/'job-summary.json').write_text(json.dumps({'mode':mode,'complete':complete,'results':all_results,'remaining_NOT_RUN':[x for x in schedule if x['status']=='NOT RUN'],'old_failed_run_unchanged':True,'F17_fixed':False},indent=2)+'\n')
if not complete:sys.exit('STOP boundary-audited diagnostic; dependent jobs NOT RUN; preserve failure, no retry/repair claim')
