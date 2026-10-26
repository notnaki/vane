#!/usr/bin/env python3
"""Pure guards for post-comparison worker image capture; no native launches."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import uuid

spec = importlib.util.spec_from_file_location("worker_engine", Path(__file__).with_name("worker-engine-evidence.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

HOST = {"pid": 100, "start": 1000, "path": "/tmp/owned.app/Contents/MacOS/vane"}
WORKER = {"pid": 200, "start": 2000, "path": "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"}

def request():
    return dict(hostPID=100, pid=200, pidStart=2000, nonce=str(uuid.uuid4()), context=str(uuid.uuid4()), stage="custom-mv3", manifestVersion=3)

def output(record): return ("UA WORKER ENGINE REQUEST " + json.dumps(record) + "\n").encode()

def sample(staged=True):
    root = "/System/Cryptexes/App/System/Library/StagedFrameworks/Safari" if staged else "/System/Library/Frameworks"
    return (f"Process: com.apple.WebKit.WebContent [200]\nPath: {WORKER['path']}\n"
            "Thread_12: WebCore: ServiceWorker\nBinary Images:\n" + "\n".join(
                f" 0x1000 - 0x2000 com.apple.{name} (21625 - 21625.1.29.18.28) <{uuid.uuid4()}> {root}/{name}.framework/Versions/A/{name}"
                for name in ("WebKit", "WebCore", "JavaScriptCore")))

class WorkerEngineTests(unittest.TestCase):
    def test_request_is_complete_unique_and_bound_to_the_actual_app(self):
        self.assertIsNone(engine.parse_request(b"UA WORKER ENGINE REQUEST {", HOST))
        record=request(); self.assertEqual(engine.parse_request(output(record), HOST), record)
        for key,value in [("pid",True),("pid",100),("pidStart",True),("pidStart",0),("hostPID",999),("nonce","../escape"),("context","bad"),("manifestVersion",2),("stage","unknown")]:
            invalid=dict(record,**{key:value})
            with self.subTest(key=key),self.assertRaises(ValueError): engine.parse_request(output(invalid),HOST)
        with self.assertRaises(ValueError): engine.parse_request(output(record)*2,HOST)

    def test_sample_requires_actual_pid_path_and_core_images_without_assuming_worker_thread_mode(self):
        text=sample(); images=engine.parse_sample(text,WORKER)
        self.assertEqual(set(images),{"WebKit","WebCore","JavaScriptCore"})
        # Page-backed service workers use the WebContent main thread. An idle
        # sample need not contain a separately named ServiceWorker thread.
        self.assertEqual(engine.parse_sample(text.replace('WebCore: ServiceWorker','MainThread'),WORKER),images)
        for invalid in [text.replace('[200]','[201]'),
                        text.replace('Path: '+WORKER['path'],'Path: /tmp/unrelated'),
                        text.replace('/Versions/A/JavaScriptCore','/Versions/A/Other'), text+'\n'+text.splitlines()[-1]]:
            with self.subTest(invalid=invalid[:40]),self.assertRaises(ValueError): engine.parse_sample(invalid,WORKER)

    def test_capture_never_samples_an_unbound_or_replaced_process_and_always_releases_valid_hold(self):
        for problem in ["host-reused","foreign-worker","wrong-pid","worker-replaced-before-delivery","worker-reused","sample-failed","sample-timeout"]:
            with self.subTest(problem=problem),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);data=root/'data';data.mkdir();logs=root/'logs';logs.mkdir()
                record=request();calls=[];worker_reads=[0]
                def identity(pid):
                    if pid==100:return dict(HOST,start=999) if problem=='host-reused' else HOST
                    worker_reads[0]+=1
                    if problem=='foreign-worker':return dict(WORKER,path='/tmp/foreign')
                    if problem=='wrong-pid':return dict(WORKER,pid=201)
                    if problem=='worker-replaced-before-delivery':return dict(WORKER,start=2001)
                    if problem=='worker-reused' and worker_reads[0]>1:return dict(WORKER,start=999)
                    return WORKER
                def invoke(command,**kwargs):
                    calls.append(command)
                    if problem=='sample-timeout':raise subprocess.TimeoutExpired(command,kwargs['timeout'],output=b'Sampling completed, processing symbols...',stderr=b'cold symbols')
                    Path(command[-1]).write_text(sample())
                    return subprocess.CompletedProcess(command,1 if problem=='sample-failed' else 0,'','failure' if problem=='sample-failed' else '')
                capture=engine.WorkerEngineCapture(data,logs,invoke=invoke,threads=lambda pid: [])
                capture(output(record),HOST,identity);capture.close()
                result=json.loads((logs/'worker-engine.json').read_text())
                self.assertEqual(result['status'],'unavailable')
                self.assertTrue((data/('ua-worker-engine-'+record['nonce']+'.done')).is_file())
                self.assertEqual(len(calls),0 if problem in {'host-reused','foreign-worker','wrong-pid','worker-replaced-before-delivery','worker-reused'} else 1)
                if problem=='sample-timeout':
                    self.assertIn('processing symbols',(logs/'worker-engine-tool.log').read_text())

    def test_sampling_does_not_block_the_owners_timeout_or_cancellation_loop(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data=root/'data';data.mkdir();logs=root/'logs';logs.mkdir()
            entered=threading.Event();release=threading.Event();returned=threading.Event()
            def invoke(command,**kwargs):
                entered.set();release.wait(2)
                raise subprocess.TimeoutExpired(command,kwargs['timeout'])
            capture=engine.WorkerEngineCapture(data,logs,invoke=invoke,threads=lambda pid: [])
            def observe():
                capture(output(request()),HOST,lambda pid:HOST if pid==100 else WORKER)
                returned.set()
            caller=threading.Thread(target=observe);caller.start()
            try:
                self.assertTrue(entered.wait(1))
                self.assertTrue(returned.wait(.5),'Owner output observer blocked while sampling')
            finally:
                release.set();caller.join(2);capture.close()

    def test_complete_capture_keeps_original_sample_and_acknowledges_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data=root/'data';data.mkdir();logs=root/'logs';logs.mkdir();record=request();calls=[]
            def invoke(command,**kwargs):
                calls.append(command);Path(command[-1]).write_text(sample())
                return subprocess.CompletedProcess(command,0,'','')
            capture=engine.WorkerEngineCapture(data,logs,invoke=invoke,threads=lambda pid: [])
            identity=lambda pid:HOST if pid==100 else WORKER
            capture(output(record),HOST,identity);capture.close();capture(output(record),HOST,identity)
            self.assertEqual(len(calls),1)
            result=json.loads((logs/'worker-engine.json').read_text())
            self.assertEqual(result['status'],'captured');self.assertEqual(result['worker'],WORKER)
            self.assertTrue((logs/'worker-engine.sample.txt').is_file())
            with self.assertRaises(ValueError): engine.validate_staged_images(engine.parse_sample(sample(staged=False),WORKER))
            engine.validate_staged_images(result['images'])

    def test_offline_verification_rejects_mismatched_requests_and_lost_native_continuity(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);data=root/'data';data.mkdir();logs=root/'trial-01';logs.mkdir();record=request()
            def invoke(command,**kwargs):
                Path(command[-1]).write_text(sample())
                return subprocess.CompletedProcess(command,0,'','')
            capture=engine.WorkerEngineCapture(data,logs,invoke=invoke,threads=lambda pid: [])
            capture(output(record),HOST,lambda pid:HOST if pid==100 else WORKER);capture.close()
            continuity=dict(nonce=record['nonce'],context=record['context'],pidBefore=200,pidAfter=200,
                            acknowledged=True,contextStillLoaded=True,sameBackgroundView=True)
            def write_log(req=record,after=continuity):
                (logs/'primary.log').write_bytes(output(req)+('UA BACKGROUND OWNER CONTINUITY '+json.dumps(after)+'\n').encode())
            write_log();engine.check_captures(root)
            for key,value in [('pidAfter',201),('contextStillLoaded',False),('acknowledged',False),('sameBackgroundView',False)]:
                write_log(after=dict(continuity,**{key:value}))
                with self.subTest(key=key),self.assertRaises(ValueError):engine.check_captures(root)
            write_log(req=dict(record,nonce=str(uuid.uuid4())))
            with self.assertRaises(ValueError):engine.check_captures(root)
            write_log()
            missing=root/'trial-02';missing.mkdir();(missing/'primary.log').write_text('UA BACKGROUND OWNER CAPTURE unavailable\n')
            with self.assertRaises(ValueError):engine.check_captures(root)

if __name__ == '__main__': unittest.main()
