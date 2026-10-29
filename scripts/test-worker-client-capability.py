#!/usr/bin/env python3
"""Offline evidence-contract controls; never an engine/UA acceptance result."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("capability", Path(__file__).with_name("worker-client-capability.py"))
capability = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capability)

def fixture():
    claim = {"schema":1,"purpose":capability.PURPOSE,"dataDirectory":"/tmp/capability-contract",
        **{k:str(uuid.uuid4()) for k in ("namespace","profileID","contextID","identityRequestNonce","resultRequestNonce")},
        "sourceFingerprint":"a"*64,"scriptSHA256":"b"*64}
    claim["storeID"] = capability.store_identifier(claim["dataDirectory"], claim["profileID"])
    origin = "webkit-extension://"+claim["contextID"]
    ua = "Mozilla/5.0 AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    identity = {"namespace":claim["namespace"],"requestNonce":claim["identityRequestNonce"],"birthNonce":str(uuid.uuid4()),
        "runtimeID":claim["contextID"],"origin":origin,"scriptURL":origin+"/worker.js","manifestVersion":3,"version":"1.0","startupUA":ua,"currentUA":ua}
    result = dict(identity,requestNonce=claim["resultRequestNonce"],snapshot={"queryCount":1,"status":"observed","clients":[
        {"id":str(uuid.uuid4()),"type":"window","frameType":"top-level","url":origin+"/"}]})
    report = {k:claim[k] for k in ("schema","namespace","profileID","storeID","contextID","sourceFingerprint","scriptSHA256")}
    report.update(runtime={"os":"26.6.2","osMajor":26,"classImagePath":"/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit","webkit":"21624.5.1.11.3","frameworkPath":"/System/Library/Frameworks/WebKit.framework"},
        lifecycle={k:True for k in ("finishedLaunching","appRunning","autoStartBadge","noExplicitBackgroundLoad","publicOnly")},
        bindings={**{k:True for k in ("pool","store","controller","visibleOwner","unsupportedNative")},"grantedPermissions":["storage"],"grantedSites":[]},
        expectedUA=ua,popupUA=ua,badgeBirthNonce=identity["birthNonce"],identity=identity,eligible=result,uaVerdict="passed",result="observed")
    verdict = {"identity":copy.deepcopy(identity),"uaVerdict":"passed"}
    return claim,report,verdict

class ProtocolTests(unittest.TestCase):
    def test_workflow_is_one_branch_one_arm_and_fails_invalid_admission(self):
        import subprocess
        workflow=(Path(__file__).resolve().parents[1]/".github/workflows/mv3-eligible-client-capability.yml").read_text()
        self.assertIn("branches: [codex/mv3-eligible-client-capability]",workflow)
        self.assertIn("contents: read",workflow)
        self.assertIn("persist-credentials: false",workflow)
        self.assertIn("runs-on: macos-26",workflow)
        self.assertEqual(workflow.count(" --run"),1)
        self.assertEqual(workflow.count("if: ${{ always() }}"),2)
        for forbidden in ("continue-on-error:","matrix:","actions/cache", "workflow_dispatch:","pull_request:","secrets.","--prepare-only"):
            self.assertNotIn(forbidden,workflow)
        block=workflow.split("        run: |\n",1)[1].split("          # Qualified build and sole capability arm.",1)[0]
        prefix="\n".join(line[10:] for line in block.splitlines())
        for values in ({}, {"GITHUB_RUN_ATTEMPT":"2"}, {"GITHUB_RUN_ATTEMPT":"1\n1"},
                       {"GITHUB_REF":"refs/heads/main"},{"GITHUB_EVENT_NAME":"pull_request"},{"GITHUB_RUN_ATTEMPT":None}):
            with tempfile.TemporaryDirectory() as directory:
                env={"PATH":os.environ["PATH"],"RUNNER_TEMP":directory,"GITHUB_REF":"refs/heads/codex/mv3-eligible-client-capability", "GITHUB_EVENT_NAME":"push", "GITHUB_RUN_ATTEMPT":"1",**values}
                env={key:value for key,value in env.items() if value is not None}
                result=subprocess.run(["bash","-c",prefix+"\ntouch \"$RUNNER_TEMP/admitted\""],env=env,capture_output=True)
                self.assertEqual(result.returncode==0,not values)
                self.assertEqual((Path(directory)/"admitted").exists(),not values)
    def test_bound_observable_capability(self):
        claim,report,verdict=fixture()
        self.assertEqual(capability.validate_report(report,claim,verdict),"observed")
    def test_no_promoted_unavailable(self):
        claim,report,verdict=fixture(); report["eligible"]["snapshot"]["clients"]=[]
        with self.assertRaises(ValueError): capability.validate_report(report,claim,verdict)
        report["result"]="unavailable"
        self.assertEqual(capability.validate_report(report,claim,verdict),"unavailable")
    def test_observed_clients_do_not_erase_ua_failure(self):
        claim,report,verdict=fixture(); report["identity"]["startupUA"]="bare engine"
        with self.assertRaises(ValueError): capability.validate_report(report,claim,verdict)
        report["uaVerdict"]="failed";report["result"]="failed"
        verdict={"identity":copy.deepcopy(report["identity"]),"uaVerdict":"failed"}
        self.assertEqual(capability.validate_report(report,claim,verdict),"failed")
    def test_forged_binding_fields(self):
        for field in ("namespace","profileID","storeID","contextID","sourceFingerprint","scriptSHA256"):
            with self.subTest(field=field):
                claim,report,verdict=fixture(); report[field]="0"*64
                with self.assertRaises((ValueError,KeyError)): capability.validate_report(report,claim,verdict)
    def test_each_reply_must_match_nonce_and_runtime(self):
        for section in ("identity","eligible"):
            for field in ("requestNonce","runtimeID","origin","scriptURL","manifestVersion","version"):
                with self.subTest(section=section,field=field):
                    claim,report,verdict=fixture();report[section][field]="wrong"
                    with self.assertRaises(ValueError): capability.validate_report(report,claim,verdict)
    def test_birth_is_independent_and_stable(self):
        for replacement in ("identityRequestNonce","resultRequestNonce"):
            claim,report,verdict=fixture();report["identity"]["birthNonce"]=claim[replacement]
            with self.assertRaises(ValueError): capability.validate_report(report,claim,verdict)
        claim,report,verdict=fixture();report["eligible"]["birthNonce"]=str(uuid.uuid4())
        with self.assertRaises(ValueError): capability.validate_report(report,claim,verdict)
    def test_foreign_or_duplicate_clients_rejected(self):
        for foreign in (True,False):
            claim,report,verdict=fixture();clients=report["eligible"]["snapshot"]["clients"]
            if foreign:clients[0]["url"]="https://foreign.invalid/"
            else:clients.append(dict(clients[0]))
            with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
    def test_staged_framework_and_expanded_access_rejected(self):
        claim,report,verdict=fixture();report["runtime"]["frameworkPath"]="/StagedFrameworks/WebKit.framework"
        with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
        claim,report,verdict=fixture();report["bindings"]["grantedPermissions"].append("nativeMessaging")
        with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
    def test_pre_result_verdict_required(self):
        claim,report,verdict=fixture()
        with self.assertRaises(ValueError):capability.validate_report(report,claim)
    def test_lifecycle_numeric_truth_not_boolean_proof(self):
        claim,report,verdict=fixture();report["lifecycle"]["autoStartBadge"]=1
        with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
    def test_store_namespace_bound_to_directory(self):
        claim,report,verdict=fixture();claim["dataDirectory"]="/tmp/sibling-capability"
        with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
    def test_runtime_and_badge_must_be_qualified(self):
        for mutate in (lambda r:r["runtime"].update(osMajor=25),lambda r:r["runtime"].update(webkit="Unavailable"),
                       lambda r:r["runtime"].update(classImagePath="/tmp/WebKit"),lambda r:r.update(badgeBirthNonce=str(uuid.uuid4()))):
            claim,report,verdict=fixture();mutate(report)
            with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
    def test_post_spawn_persistence_failure_still_retires_owned_launch(self):
        child=object();retired=[]
        def broken_save(process):
            self.assertIs(process,child)
            raise OSError("ownership evidence write failed")
        with self.assertRaises(OSError):
            capability.owned_launch(lambda:child,broken_save,lambda p:retired.append(p))
        self.assertEqual(retired,[child])
    def test_primary_and_retirement_failures_are_both_retained(self):
        def fail_body(_):raise ValueError("primary admission failure")
        def fail_retire(_):raise OSError("retirement persistence failure")
        with self.assertRaisesRegex(RuntimeError,"primary admission failure.*retirement persistence failure"):
            capability.owned_launch(object,fail_body,fail_retire)
    def test_unknown_or_ambiguous_host_is_unavailable(self):
        claim,report,verdict=fixture()
        report["eligible"]["snapshot"]["clients"].append(dict(report["eligible"]["snapshot"]["clients"][0],id=str(uuid.uuid4())))
        with self.assertRaises(ValueError):capability.validate_report(report,claim,verdict)
        report["result"]="unavailable"
        self.assertEqual(capability.validate_report(report,claim,verdict),"unavailable")
    def test_metadata_admission_waits_only_for_positive_identity(self):
        class Child:
            pid=42
            def poll(self):return None
        host={"pid":42,"start":10,"path":"/owned/vane"};observations=iter([None,host])
        value=capability.capture_launch_identity(Child(),lambda _:next(observations),lambda _:None,lambda:0)
        self.assertEqual(value,host)
    def test_exited_launch_without_identity_cannot_be_admitted(self):
        class Child:
            pid=42
            def poll(self):return 1
        self.assertIsNone(capability.capture_launch_identity(Child(),lambda _:self.fail("must not read recycled pid"),lambda _:None,lambda:0))
    def test_api_absence_does_not_claim_a_query(self):
        claim,report,verdict=fixture()
        report["eligible"]["snapshot"].update(status="api-unavailable",queryCount=0,clients=[])
        report["result"]="unavailable"
        self.assertEqual(capability.validate_report(report,claim,verdict),"unavailable")
    def test_reused_pid_is_not_signalled(self):
        host={"pid":42,"start":10,"path":"/owned/vane"};signals=[]
        capability.stop_owned(host,lambda _:dict(host,start=11),lambda *x:signals.append(x),lambda _:None,lambda:0)
        self.assertEqual(signals,[])
    def test_changed_executable_is_not_signalled(self):
        host={"pid":42,"start":10,"path":"/owned/vane"};signals=[]
        with self.assertRaises(ValueError):
            capability.stop_owned(host,lambda _:dict(host,path="/foreign/vane"),lambda *x:signals.append(x),lambda _:None,lambda:0)
        self.assertEqual(signals,[])
    def test_owned_exit_is_verified_after_signal(self):
        host={"pid":42,"start":10,"path":"/owned/vane"};signals=[]
        observations=iter([host,None])
        capability.stop_owned(host,lambda _:next(observations),lambda *x:signals.append(x),lambda _:None,lambda:0)
        self.assertEqual(len(signals),1)
    def test_preflight_blocks_foreign_driver_or_host(self):
        for command in ("/usr/bin/python3 scripts/run-native-tests.py", "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest -XCTest Test /other/VaneTests.xctest"):
            with self.assertRaises(ValueError):capability.admit_native_processes("42 1 "+command,99)
        capability.admit_native_processes("99 1 python3 worker-client-capability.py",99)
    def test_unsafe_report_files_and_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/"report.json";file.write_text('{"schema":1,"schema":1}')
            with self.assertRaises(ValueError):capability.read_json(file)
            file.write_text('{}');link=Path(directory)/"link";link.symlink_to(file)
            with self.assertRaises(OSError):capability.read_json(link)

if __name__ == "__main__": unittest.main()
