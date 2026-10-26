#!/usr/bin/env python3
"""Pure protocol/retirement guards; never launch native code."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("page_worker", Path(__file__).with_name("check-page-backed-worker-ua.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def encoded(records):
    return b"".join(("PAGE WORKER " + json.dumps(record) + "\n").encode() for record in records)

def positive(store):
    records = [dict(event="launch", scenario="page-backed-three-stage", store=store, appRunning=True, finishedLaunching=True)]
    for stage, expected in enumerate(probe.IDENTITIES):
        nonce = str(uuid.uuid4())
        records.append(dict(event="stage", stage=stage, nonce=nonce, expected=expected))
        records.extend(dict(event="request", stage=stage, nonce=nonce, kind=kind, UA=expected) for kind in ["script", "report"])
        records.append(dict(event="comparison", stage=stage, nonce=nonce, expected=expected, startup=expected, current=expected,
                            viewUA=expected, href=f"vane-worker-control://{nonce}/worker.js", matches=True,
                            scriptRequestUA=expected, reportRequestUA=expected))
    return records + [dict(event="complete", verified=3, store=store)]

class ProtocolTests(unittest.TestCase):
    def test_success_requires_all_three_bound_stages_and_exact_cleanup(self):
        store = str(uuid.uuid4()); records = positive(store)
        probe.validate_primary(encoded(records), store)
        for kind in ["bare-worker", "foreign-nonce", "missing-stage", "wrong-store", "missing-request", "duplicate-completion"]:
            changed = copy.deepcopy(records)
            if kind == "bare-worker": changed[8]["startup"] = "bare"
            elif kind == "foreign-nonce": changed[8]["nonce"] = str(uuid.uuid4())
            elif kind == "missing-stage": changed = [r for r in changed if r.get("stage") != 1]
            elif kind == "wrong-store": changed[0]["store"] = str(uuid.uuid4())
            elif kind == "missing-request": changed.pop(7)
            else: changed.append(changed[-1])
            with self.subTest(kind=kind), self.assertRaises(ValueError): probe.validate_primary(encoded(changed), store)
        cleanup = dict(event="cleanup", store=store, retired=True, error="")
        probe.validate_cleanup(encoded([cleanup]), store)
        for invalid in [dict(cleanup, retired=False), dict(cleanup, retired=1), dict(cleanup, store=str(uuid.uuid4())), dict(cleanup, error="in use")]:
            with self.assertRaises(ValueError): probe.validate_cleanup(encoded([invalid]), store)

    def test_auxiliary_request_headers_are_not_substituted_for_worker_identity(self):
        store = str(uuid.uuid4()); records = positive(store)
        for record in records:
            if record["event"] == "request": record["UA"] = "different auxiliary request identity"
            if record["event"] == "comparison":
                record.update(scriptRequestUA="different auxiliary request identity", reportRequestUA="different auxiliary request identity")
        probe.validate_primary(encoded(records), store)

    def test_failed_primary_stays_failed_and_retirement_requires_exit(self):
        for mode in ["mismatch", "not-exited", "cleanup-failed", "incomplete-success", "success"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                root=Path(folder);binary=root/'probe';binary.write_bytes(b'fake native binary');logs=root/'logs';logs.mkdir();calls=[]
                def invoke(command, environment, timeout, log, interrupted):
                    calls.append(log.stem);store=environment['PAGE_WORKER_STORE']
                    if log.stem in {'signing','signature'}:return 0,True,b''
                    if log.stem=='primary':
                        return (1 if mode in {'mismatch','not-exited'} else 0), mode!='not-exited', b'' if mode in {'mismatch','incomplete-success','not-exited'} else encoded(positive(store))
                    return (2 if mode=='cleanup-failed' else 0),True,encoded([dict(event='cleanup',store=store,retired=mode!='cleanup-failed',error='failure' if mode=='cleanup-failed' else '')])
                result=probe.run_trial(binary,root/'bundle',logs,[None],invoke=invoke)
                self.assertEqual(result==0,mode=='success')
                self.assertEqual(calls,['signing','signature','primary'] if mode=='not-exited' else ['signing','signature','primary','cleanup'])

if __name__ == '__main__': unittest.main()
