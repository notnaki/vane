#!/usr/bin/env python3
"""Physical-demand adaptation must preserve stalls and reject partial evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('scroll_frame_analysis',Path(__file__).with_name('analyze-ui-frames.py'))
analysis=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=analysis
spec.loader.exec_module(analysis)
MS=1_000_000
EPOCH=1_000_000_000


class PhysicalDemandTests(unittest.TestCase):
    def fixture(self,inputs=None):
        # Each tuple is receipt-ms, physical-event-ms, phase, momentum, dy.
        inputs=inputs or [(100,100,1,0,1),(110,110,4,0,1),(120,120,4,0,1)]
        def record(kind,ms,**extra):
            ticks=EPOCH+ms*MS
            return dict(kind=kind,ticks=ticks,uptime=ticks/1e9,y=0,key=True,
                        active=True,visible=True,width=250,height=320,documentHeight=4100,**extra)
        first,last=inputs[0][0],inputs[-1][0]
        records=[record(3,first-5),record(2,first+5),record(5,first+6,rowCount=100,rowLower=32,rowUpper=56)]
        records[1]['y']=10
        records.extend(record(1,received,eventTime=(EPOCH+physical*MS)/1e9,
                              phase=phase,momentum=momentum,dy=dy,hit=True)
                       for received,physical,phase,momentum,dy in inputs)
        records.append(record(4,last+100))
        records.sort(key=lambda r:r['ticks'])
        return dict(pid=7,reason='deadline',dropped=0,timebaseNumer=1,timebaseDenom=1,records=records)
    def frame(self,presentation,begin,context=77):
        return dict(presentation_ns=presentation*MS,display=1,
                    updates=[dict(context=context,client_begin_ns=begin*MS,context_end_ns=(presentation-2)*MS)])
    def run_adapter(self,value,frames=None,coverage=None,inventory=None):
        frames=frames if frames is not None else [self.frame(108,101),self.frame(118,111),self.frame(128,121)]
        coverage=coverage or {name:(0,1000*MS) for name in ('client','render','display')}
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'scroll.json'
            path.write_text(json.dumps(value))
            result={'target_pid':7,'target_context_inventory':inventory if inventory is not None else {
                str(context):{'submissions':[]} for context in {u['context'] for f in frames for u in f['updates']}}}
            analysis.add_scroll_trace(result,frames,path,analysis.Timebase(EPOCH,1,1),coverage,{'recorded':True})
            return result['physical_scroll']
    def test_queue_onset_and_cadence_are_separate(self):
        value=self.fixture([(300,100,1,0,1),(310,110,4,0,1)])
        result=self.run_adapter(value,[self.frame(308,301),self.frame(318,311)])
        context=result['per_context']['77']
        self.assertEqual(context['cadence_intervals']['p99_ms'],10)
        self.assertEqual(context['event_to_first_post_receipt_context_presentation']['p99_ms'],208)
        self.assertEqual(result['input_queue_latency']['p99_ms'],200)
        self.assertEqual(result['first_event_to_bounds_ms'],205)
    def test_delayed_delivery_does_not_hide_a_main_thread_stall(self):
        value=self.fixture([(100,100,1,0,1),(120,120,4,0,1),(600,140,4,0,1)])
        result=self.run_adapter(value,[self.frame(108,101),self.frame(128,121),self.frame(608,601)])
        self.assertEqual(result['per_context']['77']['cadence_intervals']['p99_ms'],480)
        self.assertEqual(result['input_queue_latency']['p99_ms'],460)
        self.assertEqual(result['explicit_gesture_segments'],1)
    def test_unexplained_hardware_timestamp_gap_is_not_called_idle(self):
        value=self.fixture([(100,100,1,0,1),(110,110,4,0,1),(600,600,4,0,1)])
        result=self.run_adapter(value,[self.frame(108,101),self.frame(118,111),self.frame(608,601)])
        self.assertEqual(result['per_context']['77']['cadence_intervals']['p99_ms'],490)
        self.assertEqual(result['explicit_gesture_segments'],1)
    def test_only_explicit_gesture_boundaries_exclude_idle(self):
        value=self.fixture([(100,100,1,0,1),(110,110,4,0,1),(112,112,8,0,0),
                            (600,600,1,0,1),(610,610,4,0,1),(612,612,8,0,0)])
        result=self.run_adapter(value,[self.frame(108,101),self.frame(118,111),self.frame(608,601),self.frame(618,611)])
        self.assertEqual(result['explicit_gesture_segments'],2)
        self.assertEqual(result['per_context']['77']['cadence_intervals'],
                         dict(n=2,p50_ms=10,average_ms=10,p95_ms=10,p99_ms=10,max_ms=10))
    def test_unpresented_tail_is_censored_with_a_latency_lower_bound(self):
        result=self.run_adapter(self.fixture(),[self.frame(108,101),self.frame(118,111)])
        self.assertFalse(result['complete_uncensored_contexts'])
        censor=result['per_context']['77']['censored_segments'][0]
        self.assertTrue(censor['last_response_missing'])
        self.assertEqual(censor['last_event_response_lower_bound_ms'],880)
    def test_contexts_are_not_interleaved_to_invent_a_faster_cadence(self):
        frames=[self.frame(108,101),self.frame(118,111,88),self.frame(128,121),self.frame(138,131,88)]
        result=self.run_adapter(self.fixture(),frames)
        self.assertEqual(result['per_context']['77']['cadence_intervals']['p99_ms'],20)
        self.assertEqual(result['per_context']['88']['cadence_intervals']['p99_ms'],20)
    def test_partial_raw_coverage_is_rejected(self):
        coverage={name:(0,119*MS) for name in ('client','render','display')}
        with self.assertRaisesRegex(analysis.InvalidTrace,'complete physical demand'):
            self.run_adapter(self.fixture(),coverage=coverage)
    def test_drop_pid_timebase_and_focus_errors_reject_quantiles(self):
        for label,mutate in [
            ('dropped',lambda value:value.update(dropped=1)),
            ('PID',lambda value:value.update(pid=8)),
            ('timebases',lambda value:value.update(timebaseDenom=2)),
            ('sampled',lambda value:value['records'][2].update(active=False)),
        ]:
            with self.subTest(label=label):
                value=copy.deepcopy(self.fixture());mutate(value)
                with self.assertRaisesRegex(analysis.InvalidTrace,label):self.run_adapter(value)
    def test_populated_count_outside_physical_demand_is_not_evidence(self):
        value=self.fixture()
        row=next(r for r in value['records'] if r['kind']==5)
        row['ticks']=EPOCH+200*MS;row['uptime']=row['ticks']/1e9
        value['records'].sort(key=lambda r:r['ticks'])
        with self.assertRaisesRegex(analysis.InvalidTrace,'populated-section'):
            self.run_adapter(value)
    def test_no_presentations_are_reported_as_censored_not_fast(self):
        result=self.run_adapter(self.fixture(),[])
        self.assertFalse(result['complete_uncensored_contexts'])
        self.assertEqual(result['no_presented_context_onset_lower_bound_ms'],900)
    def test_first_response_after_last_input_is_retained(self):
        result=self.run_adapter(self.fixture(),[self.frame(500,130)])
        self.assertIn('77',result['per_context'])
        self.assertEqual(result['per_context']['77']['event_to_first_post_receipt_context_presentation']['p99_ms'],400)
    def test_fast_context_does_not_hide_a_second_context_delayed_first_response(self):
        frames=[self.frame(108,101),self.frame(118,111),self.frame(128,121),self.frame(500,130,88)]
        result=self.run_adapter(self.fixture(),frames)
        self.assertEqual(set(result['per_context']),{'77','88'})
        self.assertEqual(result['per_context']['77']['event_to_first_post_receipt_context_presentation']['p99_ms'],8)
        self.assertEqual(result['per_context']['88']['event_to_first_post_receipt_context_presentation']['p99_ms'],400)
    def test_never_presented_and_unfinished_contexts_are_not_dropped(self):
        inventory={'77':{'submissions':[]},'88':{'submissions':[
            {'commit':1,'context_begin_ns':105*MS,'context_end_ns':None}]}}
        result=self.run_adapter(self.fixture(),inventory=inventory)
        self.assertIn('88',result['per_context'])
        self.assertFalse(result['complete_uncensored_contexts'])
        context=result['per_context']['88']
        self.assertEqual(context['unfinished_submissions'],1)
        self.assertEqual(context['cadence_intervals'],{'n':0})
        self.assertTrue(context['censored_segments'][0]['first_response_missing'])
        self.assertFalse(context['complete_uncensored'])
    def test_complete_submission_without_presentation_is_censored(self):
        inventory={'88':{'submissions':[
            {'commit':1,'context_begin_ns':105*MS,'context_end_ns':106*MS}]}}
        result=self.run_adapter(self.fixture(),[],inventory=inventory)
        self.assertFalse(result['complete_uncensored_contexts'])
        self.assertFalse(result['per_context']['88']['complete_uncensored'])
        self.assertEqual(result['per_context']['88']['submissions_without_exact_observed_presentation'],1)
        self.assertEqual(result['no_presented_context_onset_lower_bound_ms'],900)
    def test_static_context_is_reported_without_assuming_sidebar_attribution(self):
        inventory={'77':{'submissions':[]},'88':{'submissions':[
            {'commit':1,'context_begin_ns':10*MS,'context_end_ns':11*MS}]}}
        result=self.run_adapter(self.fixture(),inventory=inventory)
        self.assertIn('88',result['per_context'])
        self.assertEqual(result['per_context']['88']['attribution'],'unknown; may be static or unrelated to the sidebar')
        self.assertFalse(result['complete_uncensored_contexts'])
    def test_populated_space_cannot_shrink_to_ten_rows(self):
        value=self.fixture()
        record=copy.deepcopy(next(r for r in value['records'] if r['kind']==5))
        record.update(ticks=EPOCH+115*MS,uptime=(EPOCH+115*MS)/1e9,rowCount=10)
        value['records'].append(record);value['records'].sort(key=lambda r:r['ticks'])
        with self.assertRaisesRegex(analysis.InvalidTrace,'row count changed'):
            self.run_adapter(value)
    def test_empty_pinned_section_is_allowed_with_one_hundred_today_rows(self):
        value=self.fixture()
        record=copy.deepcopy(next(r for r in value['records'] if r['kind']==5))
        record.update(ticks=EPOCH+115*MS,uptime=(EPOCH+115*MS)/1e9,rowCount=0)
        value['records'].append(record);value['records'].sort(key=lambda r:r['ticks'])
        self.assertEqual(self.run_adapter(value)['row_counts_observed'],[0,100])


if __name__=='__main__':unittest.main()
