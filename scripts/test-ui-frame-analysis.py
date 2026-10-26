#!/usr/bin/env python3
"""Exact identity joins must reject misleading presentation associations."""
import importlib.util
import contextlib
import io
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('ui_frame_analysis',Path(__file__).with_name('analyze-ui-frames.py'))
analysis=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=analysis
spec.loader.exec_module(analysis)
Event=analysis.Event
Timebase=analysis.Timebase
InvalidTrace=analysis.InvalidTrace
join=analysis.join
class SelfTests(unittest.TestCase):
    def test_auxiliary_timestamp_does_not_replace_exact_identity_join(self):
        ca,d0,d1,tb=self.data()
        d1=[Event(e.ns,e.thread,e.code,e.fn,(*e.args[:3],18058749469622)) if e.code==81 else e for e in d1]
        result,frames=join(ca,d0,d1,tb,7)
        self.assertEqual(len(frames),1)
        self.assertEqual(result['diagnostics']['target_context_composites_with_auxiliary_value'],2)
    def test_nearest_rank_percentiles_include_the_tail(self):
        stats=analysis.stats_ns([x*1_000_000 for x in range(1,101)])
        self.assertEqual(stats,{'n':100,'p50_ms':50,'average_ms':50.5,'p95_ms':95,'p99_ms':99,'max_ms':100})
    def data(self):
        tb=Timebase(0,1,1);client=(7,1);server=(9,2);present=(9,3)
        ca=[Event(10,client,1,1,(0,1,0,0)),Event(11,client,119,1,(77,0,1,0)),Event(12,client,119,2,(1,0,0,0)),Event(13,client,1,2,(0,0,0,0))]
        bits=lambda x:struct.unpack('<Q',struct.pack('<d',x/1e9))[0]
        d0=[];d1=[]
        for seed,start,commit in [(100,20,1),(101,40,1)]:
            d0.extend([Event(start,server,41,1,(seed,0,1,1)),Event(start+5,server,41,2,(0,0,1,2))])
            d1.extend([Event(start+2,server,81,0,(77,7,commit,0)),Event(start+11,present,82,1,(seed,1,1,start+10)),Event(start+12,present,82,2,(bits(start),bits(start+2),3,8_333_333))])
        return ca,d0,d1,tb
    def test_exact_bridge_and_repeated_composition(self):
        r,f=join(*self.data(),7);self.assertEqual(len(f),1);self.assertEqual(r['diagnostics']['repeated_context_commit_composites'],1)
    def test_no_nearest_commit_fabrication(self):
        ca,d0,d1,tb=self.data();d1=[Event(e.ns,e.thread,e.code,e.fn,(88,*e.args[1:])) if e.code==81 else e for e in d1]
        r,f=join(ca,d0,d1,tb,7);self.assertFalse(f);self.assertEqual(r['diagnostics']['new_tuple_without_captured_client_context_commit'],1)
    def test_missing_presentation_excluded(self):
        ca,d0,d1,tb=self.data();r,f=join(ca,d0,[e for e in d1 if e.code!=82],tb,7);self.assertFalse(f)
    def test_old_frame_seed_slot_does_not_join(self):
        ca,d0,d1,tb=self.data();d0=[Event(e.ns,e.thread,e.code,e.fn,(0,e.args[0],1,1)) if e.fn==1 else e for e in d0]
        r,f=join(ca,d0,d1,tb,7);self.assertFalse(f)
    def test_d1_qualifier_change_rejected(self):
        ca,d0,d1,tb=self.data();d1=[Event(e.ns,e.thread,e.code,1,e.args) if e.code==81 else e for e in d1]
        with self.assertRaises(InvalidTrace):join(ca,d0,d1,tb,7)
    def test_two_contexts_one_transaction_present_once(self):
        ca,d0,d1,tb=self.data();client=(7,1)
        ca.extend([Event(11,client,119,1,(88,0,1,0)),Event(12,client,119,2,(1,0,0,0))])
        d1.extend(Event(e.ns,e.thread,e.code,e.fn,(88,*e.args[1:])) for e in list(d1) if e.code==81)
        r,f=join(ca,d0,d1,tb,7)
        self.assertEqual(r['diagnostics']['new_context_updates_presented'],2)
        self.assertEqual(r['diagnostics']['unique_client_commits_presented'],1)
        self.assertEqual(len(f),1)
    def test_backwards_context_id_rejected(self):
        ca,d0,d1,tb=self.data();d1=[Event(e.ns,e.thread,e.code,e.fn,(77,7,0,0)) if e.code==81 and e.ns>40 else e for e in d1]
        with self.assertRaises(InvalidTrace):join(ca,d0,d1,tb,7)
    def test_backwards_presentation_rejected(self):
        ca,d0,d1,tb=self.data();d1=[Event(e.ns,e.thread,e.code,e.fn,(*e.args[:3],29)) if e.code==82 and e.fn==1 and e.args[0]==101 else e for e in d1]
        with self.assertRaises(InvalidTrace):join(ca,d0,d1,tb,7)
    def test_unobserved_commit_is_censored(self):
        ca,d0,d1,tb=self.data();ca.extend([Event(60,(7,1),1,1,(0,2,0,0)),Event(70,(7,1),1,2,(0,0,0,0))])
        r,f=join(ca,d0,d1,tb,7)
        self.assertEqual(r['diagnostics']['client_commits_without_exact_observed_presentation'],1)
    def test_no_default_cadence(self):
        r,f=join(*self.data(),7);self.assertIsNone(r['presentation_cadence']);self.assertNotIn('fps',r)
    def test_inventory_includes_unfinished_and_never_presented_contexts(self):
        ca,d0,d1,tb=self.data()
        ca.extend([Event(60,(7,1),119,1,(88,0,2,0)),
                   Event(61,(8,1),119,1,(99,0,2,0))])
        r,_=join(ca,d0,d1,tb,7)
        self.assertEqual(set(r['target_context_inventory']),{'77','88'})
        submission=r['target_context_inventory']['88']['submissions'][0]
        self.assertEqual(submission['commit'],2)
        self.assertEqual(submission['context_begin_ns'],60)
        self.assertIsNone(submission['context_end_ns'])
    def test_legacy_segments_api_is_removed(self):
        error=io.StringIO()
        with patch.object(sys,'argv',['analyze-ui-frames.py','--run','.','--output','unused',
                                      '--segments','unverified.json']),contextlib.redirect_stderr(error):
            with self.assertRaises(SystemExit) as rejected:analysis.main()
        self.assertEqual(rejected.exception.code,2)
        self.assertIn('unrecognized arguments: --segments',error.getvalue())

if __name__=='__main__':unittest.main()
