#!/usr/bin/env python3
"""One owned native attachment diagnostic. Never qualifies motion timing."""
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import time

SOURCE = "3bcc08e7729bcd7544f9a030499f453feb427cec"
TEST = "VaneTests.SpaceNativeRenderingTests/testCachedProfileColourStaysContinuousAcrossRepeatedSwipes"
CALLBACK = r'''
import lldb,json,os,time
from pathlib import Path
out=Path(os.environ['VANE_SCROLL_OWNER_OUTPUT'])
root=os.path.realpath(os.environ['VANE_SCROLL_OWNER_ROOT'])+'/'
count=0
failed=False
seen=set()

def emit(value):
    with (out/'events.jsonl').open('a') as f:f.write(json.dumps(value)+'\n')

def event(frame,location,internal_dict):
    global count,failed
    if failed:return False
    process=frame.GetThread().GetProcess();target=process.GetTarget()
    count+=1
    modules=[os.path.realpath(str(m.GetFileSpec())) for m in target.module_iter()]
    owned=any(p.startswith(root) and '.xctest/' in p for p in modules)
    if count>256 or not owned:
        failed=True;emit({'kind':'incomplete','reason':'event limit or ownership','owned':owned,'count':count});return False
    receiver=frame.FindRegister('x0').GetValueAsUnsigned()
    name=frame.GetFunctionName() or ''
    entry={'kind':'dealloc' if 'dealloc' in name else 'attachment','pid':process.GetProcessID(),'receiver':receiver,'name':name,'owned':owned,'time':time.monotonic()}
    if entry['kind']=='dealloc':
        if receiver in seen:emit(entry)
        return False
    seen.add(receiver)
    entry['newWindow']=frame.FindRegister('x2').GetValueAsUnsigned()
    entry['stack']=[f.GetFunctionName() for f in list(frame.GetThread())[:30]]
    expression=r"""
@import AppKit;
({ NSView *origin=(NSView *)ADDRESS;
NSMutableArray *ancestors=[NSMutableArray array];
NSView *v=origin;
for (int i=0;v && i<12;i++,v=[v superview]) {
 [ancestors addObject:@{@"address":@((unsigned long long)v),@"class":NSStringFromClass([v class]),@"frame":NSStringFromRect([v frame]),@"window":@((unsigned long long)[v window])}];
}
NSMutableArray *queue=[NSMutableArray arrayWithObject:origin];
NSMutableArray *descendants=[NSMutableArray array];
for (NSUInteger i=0;i<[queue count] && i<96;i++) {
 NSView *n=[queue objectAtIndex:i];
 [descendants addObject:@{@"address":@((unsigned long long)n),@"class":NSStringFromClass([n class]),@"parent":@((unsigned long long)[n superview]),@"frame":NSStringFromRect([n frame])}];
 if ([queue count]<96) for(NSView *child in [n subviews]) { if([queue count]>=96)break;[queue addObject:child]; }
}
NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"ancestors":ancestors,@"descendants":descendants,@"bounded":@([queue count]>=96 || v!=nil)} options:0 error:nil];
[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; })
"""
    options=lldb.SBExpressionOptions();options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetIgnoreBreakpoints(True);options.SetTimeoutInMicroSeconds(500000);options.SetTryAllThreads(False)
    value=frame.EvaluateExpression(expression.replace('ADDRESS',hex(receiver)),options)
    if value.GetError().Fail():
        failed=True;entry['inspectionError']=str(value.GetError());emit(entry);return False
    description=value.GetObjectDescription()
    try:entry['tree']=json.loads(description)
    except Exception:
        failed=True;entry['inspectionError']='No JSON object description';entry['raw']=description
    emit(entry)
    return False

def __lldb_init_module(debugger,internal_dict):
    target=debugger.GetSelectedTarget()
    emit({'kind':'setup','exe':str(target.GetExecutable()),'triple':target.GetTriple()})
    for name in ['-[NSScrollView _setWindow:]','-[NSScrollView dealloc]']:
        bp=target.BreakpointCreateByName(name);bp.SetScriptCallbackFunction(__name__+'.event')
        emit({'kind':'breakpoint','name':name,'id':bp.GetID(),'locations':bp.GetNumLocations()})
    print('SCROLL_OWNER_READY')
'''


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path.cwd().resolve()
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == SOURCE
    assert subprocess.check_output(["uname", "-m"], text=True).strip() == "arm64"
    assert subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip().split(".")[0] == "26"
    helptext = subprocess.check_output(["swift", "test", "--help"], text=True)
    if "--debugger" not in helptext:
        (out / "result.json").write_text(json.dumps({"complete": False, "reason": "SwiftPM debugger unavailable; no fallback"}))
        return 1
    callback = out / "scroll_owner.py"
    callback.write_text(CALLBACK)
    env = dict(os.environ, VANE_SCROLL_OWNER_OUTPUT=str(out), VANE_SCROLL_OWNER_ROOT=str(root),
               VANE_NATIVE_FIXTURE_PRIMARY_TIMEOUT="120")
    command = ["python3", "scripts/run-native-tests.py", "--skip-build", "--jobs", "1",
               "--filter", "^" + re.escape(TEST) + "$", "--debugger"]
    (out / "command.json").write_text(json.dumps({"source": SOURCE, "command": command, "diagnosticOnly": True, "attempts": 1}, indent=2))
    master, slave = pty.openpty()
    child = subprocess.Popen(command, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    data = b""
    prepared = ran = quit_sent = timed_out = False
    start = last = time.monotonic()
    with (out / "native-debugger.log").open("wb") as log:
        while child.poll() is None:
            readable, _, _ = select.select([master], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    data += chunk
                    log.write(chunk)
                    log.flush()
                    last = time.monotonic()
            if not prepared and b"target select 0" in data and data.rstrip().endswith(b"(lldb)") and time.monotonic() - last > 0.2:
                os.write(master, ("command script import " + str(callback) + "\n").encode())
                prepared = True
            elif prepared and not ran and b"SCROLL_OWNER_READY" in data and data.rstrip().endswith(b"(lldb)"):
                os.write(master, b"run\n")
                ran = True
            if ran and not quit_sent and b"All testing targets completed." in data and data.rstrip().endswith(b"(lldb)"):
                os.write(master, b"target select 0\nbreakpoint list\nquit\n")
                quit_sent = True
            if time.monotonic() - start > 225:
                timed_out = True
                # The driver retains responsibility for exact host validation and cleanup.
                child.terminate()
                break
        try:
            status = child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            (out / "result.json").write_text(json.dumps({"complete": False, "reason": "Driver did not exit; cleanup unresolved", "driverPid": child.pid}))
            return 1
        while select.select([master], [], [], 0)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            log.write(chunk)
    os.close(master)
    text = data.decode("utf-8", errors="replace").replace("\r", "")
    events_path = out / "events.jsonl"
    events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
    attachments = [item for item in events if item.get("kind") == "attachment"]
    incomplete = any(item.get("kind") == "incomplete" or "inspectionError" in item
                     or item.get("tree", {}).get("bounded") is True for item in events)
    observed = re.findall(
        r"Test Case '-\[VaneTests\.SpaceNativeRenderingTests testCachedProfileColourStaysContinuousAcrossRepeatedSwipes\]' (passed|failed|skipped) ",
        text,
    )
    cleanup = "Native suite primary status=0; cleanup status=0" in text
    # Debugger exit status is not XCTest status. Preserve the actual method
    # outcome and never call an instrumented pass qualification.
    complete = (status == 0 and quit_sent and not timed_out and not incomplete
                and len(observed) == 1 and observed[0] != "skipped"
                and bool(attachments) and cleanup
                and text.count("locations = 1, resolved = 1, hit count") == 2)
    (out / "result.json").write_text(json.dumps({
        "diagnosticOnly": True, "prepared": prepared, "ran": ran, "quitSent": quit_sent,
        "driverStatus": status, "timedOut": timed_out,
        "complete": complete, "qualified": False, "testOutcomes": observed,
        "inspectionIncomplete": incomplete, "attachmentEvents": len(attachments),
        "cleanupVerified": cleanup,
    }, indent=2))
    return status or (0 if complete else 1)


if __name__ == "__main__":
    sys.exit(main())
