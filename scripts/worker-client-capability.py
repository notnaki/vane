#!/usr/bin/env python3
"""Separate opt-in normal-app capability and namespace-only diagnostics; no UA repair."""
import hashlib
import json
import os
import re
from pathlib import Path
import stat
import uuid
from urllib.parse import urlsplit

PURPOSE = "Vane MV3 eligible-client capability"
NAMESPACE_PURPOSE = "Vane cold named-store cleanup regression"
SOURCE_PIN = "26695efdefc6076049ec50713a2c4e54b90b4d47"
LATER_PIN = "da4d88f94a06e713938e0aa76943578d00626772"


def identifier(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("identifier must be a canonical UUID")
    return value


def digest(value):
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError("invalid source fingerprint")
    return value


def store_identifier(directory, profile):
    value = bytearray(hashlib.sha256(("Vane.WebsiteData.v1\0" + str(Path(directory).resolve()) + "\0" + identifier(profile)).encode()).digest()[:16])
    value[:4] = b"VANE"
    value[6] = (value[6] & 15) | 128
    value[8] = (value[8] & 63) | 128
    return str(uuid.UUID(bytes=bytes(value)))


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 65536:
            raise ValueError("report must be an owned regular file <=64KiB")
        data = os.read(descriptor, 65537)
        if len(data) > 65536:
            raise ValueError("oversized report")
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError("duplicate JSON key")
                result[key] = value
            return result
        return json.loads(data, object_pairs_hook=unique)
    finally:
        os.close(descriptor)


def validate_report(report, claim, verdict=None):
    if type(claim.get("schema")) is not int or claim["schema"] != 1 or claim.get("purpose") != PURPOSE:
        raise ValueError("claim schema/purpose mismatch")
    for key in ("namespace", "profileID", "storeID", "contextID", "identityRequestNonce", "resultRequestNonce"):
        identifier(claim[key])
    if len({claim[k] for k in ("namespace", "profileID", "contextID", "identityRequestNonce", "resultRequestNonce")}) != 5:
        raise ValueError("independent identity nonces reused")
    if claim["storeID"] != store_identifier(claim["dataDirectory"], claim["profileID"]):
        raise ValueError("store is outside this exact profile/directory namespace")
    if report.get("schema") != 1 or type(report["schema"]) is not int:
        raise ValueError("report schema mismatch")
    for key in ("namespace", "profileID", "storeID", "contextID", "sourceFingerprint", "scriptSHA256"):
        if report.get(key) != claim[key]: raise ValueError("report namespace/source mismatch: " + key)
    digest(report["sourceFingerprint"]); digest(report["scriptSHA256"])
    runtime = report["runtime"]
    for key in ("os", "webkit"):
        if not isinstance(runtime.get(key), str) or not runtime[key] or len(runtime[key]) > 160:
            raise ValueError("missing runtime qualification")
    if type(runtime.get("osMajor")) is not int or runtime["osMajor"] < 26 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,}",runtime["webkit"]):
        raise ValueError("runtime version is unqualified")
    if not runtime.get("classImagePath", "").startswith("/System/Library/Frameworks/WebKit.framework/"):
        raise ValueError("class is not loaded from system WebKit")
    if runtime.get("frameworkPath") != "/System/Library/Frameworks/WebKit.framework":
        raise ValueError("not system WebKit")
    for key in ("finishedLaunching", "appRunning", "autoStartBadge", "noExplicitBackgroundLoad", "publicOnly"):
        if report["lifecycle"].get(key) is not True:
            raise ValueError("missing public lifecycle prerequisite: " + key)
    for key in ("pool", "store", "controller", "visibleOwner", "unsupportedNative"):
        if report["bindings"].get(key) is not True: raise ValueError("wrong actual owner: " + key)
    if report["bindings"].get("grantedPermissions") != ["storage"] or report["bindings"].get("grantedSites") != []:
        raise ValueError("probe expanded access")
    expected = report["expectedUA"]
    if not isinstance(expected, str) or len(expected) > 2048 or " Version/" not in expected or " Safari/" not in expected:
        raise ValueError("expected default Safari identity missing")
    identity = report["identity"]
    result = report["eligible"]
    origin = "webkit-extension://" + claim["contextID"]
    for value, request in ((identity, "identityRequestNonce"), (result, "resultRequestNonce")):
        for key, wanted in (("namespace", claim["namespace"]), ("requestNonce", claim[request]),
                            ("runtimeID", claim["contextID"]), ("origin", origin),
                            ("scriptURL", origin + "/worker.js"), ("manifestVersion", 3), ("version", "1.0")):
            if value.get(key) != wanted: raise ValueError("stale/wrong worker reply: " + key)
        if type(value["manifestVersion"]) is not int: raise ValueError("manifest type mismatch")
    birth = identifier(identity["birthNonce"])
    if birth in {claim[k] for k in ("namespace", "contextID", "identityRequestNonce", "resultRequestNonce")}:
        raise ValueError("worker birth nonce is not independent")
    if result.get("birthNonce") != birth or report.get("badgeBirthNonce") != birth:
        raise ValueError("worker changed between badge/identity/result")
    ua_pass = identity.get("startupUA") == expected and identity.get("currentUA") == expected and report.get("popupUA") == expected
    if report.get("uaVerdict") != ("passed" if ua_pass else "failed"):
        raise ValueError("original UA verdict was rewritten")
    if verdict is None or verdict.get("identity") != identity or verdict.get("uaVerdict") != report["uaVerdict"]:
        raise ValueError("original pre-result verdict not preserved")
    snapshot = result["snapshot"]
    expected_queries = 0 if snapshot.get("status") == "api-unavailable" else 1
    if type(snapshot.get("queryCount")) is not int or snapshot["queryCount"] != expected_queries:
        raise ValueError("eligible query must run exactly once")
    clients = snapshot.get("clients")
    if not isinstance(clients, list) or len(clients) > 32: raise ValueError("unbounded eligible set")
    seen = set(); hosting = []
    for client in clients:
        identifier(client["id"])
        if client["id"] in seen: raise ValueError("duplicate eligible client")
        seen.add(client["id"])
        url = urlsplit(client["url"])
        if url.scheme != "webkit-extension" or url.hostname != claim["contextID"] or url.username or url.password or url.port is not None:
            raise ValueError("foreign eligible client")
        if client["type"] == "window" and client["frameType"] == "top-level" and url.path in ("", "/") and not url.query and not url.fragment:
            hosting.append(client)
    observable = snapshot.get("status") == "observed" and len(hosting) == 1
    classification = "failed" if not ua_pass else "observed" if observable else "unavailable"
    if report.get("result") != classification: raise ValueError("capability outcome was promoted")
    return classification


def source_fingerprint(root):
    files = sorted([*root.glob("Sources/Vane/**/*.swift"), root/"Package.swift", root/"Vane.entitlements",
                    *root.glob("Tests/Diagnostics/WorkerClientCapability/*"),
                    root/"scripts/worker-client-capability.py",root/"scripts/test-worker-client-capability.py",
                    root/"scripts/run-native-tests.py",root/".github/workflows/mv3-eligible-client-capability.yml"])
    values = {str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest(), values


def validate_namespace_pair(creation, cleanup, claim, hosts):
    if type(claim.get("schema")) is not int or claim["schema"] != 1 or claim.get("purpose") != NAMESPACE_PURPOSE:
        raise ValueError("wrong namespace-regression purpose")
    for key in ("namespace", "profileID", "storeID"):identifier(claim[key])
    digest(claim["sourceFingerprint"])
    if claim["storeID"] != store_identifier(claim["dataDirectory"],claim["profileID"]):
        raise ValueError("foreign named-store namespace")
    for report,phase in ((creation,"namespace-create"),(cleanup,"namespace-cleanup")):
        for key in ("schema","purpose","namespace","profileID","storeID","sourceFingerprint","appBundleID"):
            if report.get(key)!=claim[key]:raise ValueError("namespace report binding mismatch: "+key)
        if type(report["schema"]) is not int or report.get("phase")!=phase or report.get("noExtensionWorkerOrPage") is not True:
            raise ValueError("not the namespace-only operation")
        runtime=report["runtime"]
        if not isinstance(runtime.get("os"),str) or not runtime["os"] or len(runtime["os"])>160:raise ValueError("missing OS qualification")
        if type(runtime.get("osMajor")) is not int or runtime["osMajor"]<26 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,}",runtime.get("webkit","")):
            raise ValueError("unqualified namespace runtime")
        if runtime.get("frameworkPath")!="/System/Library/Frameworks/WebKit.framework" or not runtime.get("classImagePath","").startswith("/System/Library/Frameworks/WebKit.framework/"):
            raise ValueError("not system WebKit")
        if type(report.get("pid")) is not int:raise ValueError("missing actual phase PID")
    if creation["runtime"]!=cleanup["runtime"]:raise ValueError("runtime changed between namespace processes")
    if len(hosts)!=2:raise ValueError("requires exactly creation and fresh cleanup hosts")
    for record,report in zip(hosts,(creation,cleanup)):
        if record.get("ownedLaunchExited") is not True or record["host"]["pid"]!=report["pid"]:
            raise ValueError("owned launch/exit proof missing")
    first,second=(record["host"] for record in hosts)
    if (first["pid"],first["start"])==(second["pid"],second["start"]) or first["path"]!=second["path"] or cleanup.get("creatorPID")!=creation["pid"]:
        raise ValueError("cleanup is not a fresh same-container launch")
    for report,section,keys in ((creation,"admission",("beforeAbsent","cookieVerified","afterPresent")),
                                (cleanup,"admission",("creatorVerified","beforePresent")),
                                (cleanup,"retirement",("afterAbsent","removalAttempted"))):
        if any(type(report[section].get(key)) is not bool for key in keys):raise ValueError("untyped namespace admission/retirement")
    errors=cleanup.get("removalErrors")
    if not isinstance(errors,list) or any(not isinstance(error,str) for error in errors):raise ValueError("removal errors were not retained")
    def count(report,key,wanted):return type(report.get(key)) is int and report[key]==wanted
    created=all(creation["admission"].values()) and not creation.get("failure") and all(count(creation,key,n) for key,n in (("registryCallbackCount",2),("cookieWriteCallbackCount",1),("cookieReadCallbackCount",1)))
    retired=all(cleanup["admission"].values()) and all(cleanup["retirement"].values()) and not errors and not cleanup.get("failure") and count(cleanup,"registryCallbackCount",2) and count(cleanup,"removalCallbackCount",1)
    if creation.get("result")!=("created" if created else "failed") or cleanup.get("result")!=("retired" if retired else "failed"):
        raise ValueError("namespace qualification was promoted")
    return "retired" if created and retired else "failed"


def admit_native_processes(snapshot, own_pid):
    foreign = []
    for line in snapshot.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3 or int(fields[0]) == own_pid: continue
        command = fields[2]; name = Path(command.split(None,1)[0]).name.lower()
        if name == "xctest" or (name.startswith("python") and any(token in command for token in
                ("run-native-tests.py", "check-extension-ua.py", "run-bitwarden-acceptance.py", "worker-client-capability.py"))):
            foreign.append(line)
    if foreign: raise ValueError("foreign native driver/host present: " + repr(foreign))


def capture_launch_identity(process, identity, pause, now):
    deadline=now()+2
    while process.poll() is None:
        try:
            host=identity(process.pid)
            if host is not None:return host
        except ValueError:pass  # exec/exit can briefly make public proc metadata unavailable
        if now()>=deadline:raise ValueError("launched host kernel identity unavailable")
        pause(.01)
    return None


def owned_launch(create, body, retire):
    process = None
    failure = None
    try:
        process = create()
        return body(process)
    except BaseException as error:
        failure = error
        raise
    finally:
        if process is not None:
            try:retire(process)
            except BaseException as error:
                if failure is not None:
                    raise RuntimeError(f"Primary launch: {failure}; retirement: {error}") from error
                raise


def matches_owned_crash(raw, host, bundle_id):
    from datetime import datetime,timezone
    try:
        decoder=json.JSONDecoder();text=raw.decode("utf-8").strip()
        first,end=decoder.raw_decode(text);remaining=text[end:].strip()
        body,end=decoder.raw_decode(remaining) if remaining else (first,len(text))
        if remaining and remaining[end:].strip():return False
        if first.get("bundleID",bundle_id)!=bundle_id or body.get("bundleInfo",{}).get("CFBundleIdentifier")!=bundle_id:return False
        if type(body.get("pid")) is not int or body["pid"]!=host["pid"] or os.path.realpath(body.get("procPath",""))!=host["path"]:return False
        stamp=body["procLaunch"];fraction=re.search(r"\.(\d{3,6}) ",stamp)
        if not fraction:return False
        launch=datetime.strptime(stamp,"%Y-%m-%d %H:%M:%S.%f %z")-datetime(1970,1,1,tzinfo=timezone.utc)
        micros=(launch.days*86400+launch.seconds)*1000000+launch.microseconds
        # Apple reports may truncate launch time to100us. The exact kernel-start
        # identity remains in ownership.json; match only within reported precision.
        return abs(micros-host["start"])<10**(6-len(fraction[1]))
    except (ValueError,KeyError,TypeError,AttributeError):return False


def collect_owned_crashes(host,bundle_id,evidence,label):
    import time
    result={"ownedHost":host,"bundleID":bundle_id,"reports":[],"available":False}
    output=evidence/(label+"-owned-crashes");output.mkdir()
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        for directory in (Path.home()/"Library/Logs/DiagnosticReports",Path("/Library/Logs/DiagnosticReports")):
            for path in directory.glob("*.ips"):
                if not path.name.lower().startswith("vane"):continue
                try:
                    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
                    try:
                        info=os.fstat(descriptor)
                        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0,os.geteuid()) or info.st_size>4*1024*1024:continue
                        raw=os.read(descriptor,4*1024*1024+1)
                    finally:os.close(descriptor)
                    if len(raw)>4*1024*1024 or not matches_owned_crash(raw,host,bundle_id):continue
                    target=output/path.name;target.write_bytes(raw)
                    result["reports"].append({"name":path.name,"sha256":hashlib.sha256(raw).hexdigest()})
                except OSError:continue
        if result["reports"]:result["available"]=True;break
        time.sleep(.05)
    if not result["available"]:result["unavailableReason"]="No exact owned report published within the bounded postmortem interval"
    (output/"index.json").write_text(json.dumps(result,indent=2)+"\n")


def stop_owned(host, identity, send, pause, now):
    import signal
    for signum in (signal.SIGTERM, signal.SIGKILL):
        observed = identity(host["pid"])
        if observed is None or observed["start"] != host["start"]: return
        if observed != host: raise ValueError("owned process executable/identity changed; no signal")
        send(host["pid"], signum)
        deadline = now() + 2
        while now() < deadline:
            try:observed = identity(host["pid"])
            except ValueError:
                pause(.02);continue  # no further signal without positive revalidation
            if observed is None or observed["start"] != host["start"]: return
            if observed != host: raise ValueError("owned process changed during retirement")
            pause(.02)
    raise ValueError("owned process remains after validated retirement")


def main():
    import argparse
    import importlib.util
    import plistlib
    import shutil
    import signal
    import subprocess
    import sys
    import tempfile
    import time
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare-only", action="store_true")
    mode.add_argument("--run", action="store_true", help="one native/UI arm; requires separately coordinated lease")
    mode.add_argument("--namespace-regression", action="store_true", help="one namespace creation and fresh cleanup; no worker")
    mode.add_argument("--prepare-namespace", action="store_true", help="sign namespace fixture without launching it")
    args=parser.parse_args()
    namespace_only=args.namespace_regression or args.prepare_namespace
    prepare_only=args.prepare_only or args.prepare_namespace
    if sys.platform != "darwin": parser.error("requires macOS26+ and a coordinated GUI session")
    if any(key.startswith("DYLD_") or key.startswith("WEBKIT_") for key in os.environ):
        parser.error("engine override/tracing environment is not accepted")
    root=Path(__file__).resolve().parents[1]
    evidence=args.evidence_dir.resolve()
    if evidence.exists(): parser.error("evidence directory must be fresh; preserve all prior attempts")
    evidence.mkdir(parents=True, mode=0o700)
    binary=args.binary.resolve()
    marker=b"namespace-store-cleanup" if namespace_only else b"worker-client-capability-cleanup"
    if not binary.is_file() or marker not in binary.read_bytes():
        parser.error("built DEBUG capability executable is missing")
    fingerprint, sources=source_fingerprint(root)
    (evidence/"source-fingerprint.json").write_text(json.dumps({"fingerprint":fingerprint,"files":sources},indent=2)+"\n")
    downloads=Path.home()/"Downloads"
    if not downloads.is_dir(): parser.error("Downloads directory is required for existing sandbox entitlement")
    data=Path(tempfile.mkdtemp(prefix=".vane-client-capability-",dir=downloads)).resolve()
    namespace=str(uuid.uuid4()); profile=str(uuid.uuid4()); context=str(uuid.uuid4())
    bundle_id="io.github.notnaki.vane."+("namespace-cleanup." if namespace_only else "client-capability.")+uuid.uuid4().hex
    claim={"schema":1,"purpose":PURPOSE,"namespace":namespace,"profileID":profile,"contextID":context,
           "identityRequestNonce":str(uuid.uuid4()),"resultRequestNonce":str(uuid.uuid4()),
           "dataDirectory":str(data),"storeID":store_identifier(data,profile),"sourceFingerprint":fingerprint}
    if namespace_only:
        claim={key:value for key,value in claim.items() if key not in ("contextID","identityRequestNonce","resultRequestNonce")}
        claim.update(purpose=NAMESPACE_PURPOSE,appBundleID=bundle_id)
    else:
        fixture=data/"fixture";fixture.mkdir()
        for path in (root/"Tests/Diagnostics/WorkerClientCapability").iterdir():
            content=path.read_bytes()
            if path.name=="worker.js":content=content.replace(b'"@NAMESPACE@"',json.dumps(namespace).encode())
            (fixture/path.name).write_bytes(content)
        claim["scriptSHA256"]=hashlib.sha256((fixture/"worker.js").read_bytes()).hexdigest()
    (data/"capability-claim.json").write_text(json.dumps(claim,indent=2)+"\n")
    (evidence/"claim.json").write_text(json.dumps(claim,indent=2)+"\n")
    app=evidence/("Vane Namespace Cleanup.app" if namespace_only else "Vane Client Capability.app");executable=app/"Contents/MacOS/vane"
    executable.parent.mkdir(parents=True);shutil.copy2(binary,executable)
    resources=app/"Contents/Resources";resources.mkdir()
    for bundle in binary.parent.glob("*.bundle"):shutil.copytree(bundle,resources/bundle.name)
    info={"CFBundleIdentifier":bundle_id,
          "CFBundleExecutable":"vane","CFBundleName":"Vane Client Capability","CFBundlePackageType":"APPL",
          "CFBundleVersion":"1","CFBundleShortVersionString":"0.1","NSPrincipalClass":"NSApplication","LSMinimumSystemVersion":"26.0"}
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    def checked(command,name):
        result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (evidence/name).write_bytes(result.stdout)
        if result.returncode:raise ValueError("signing/provenance prerequisite failed: "+name)
        return result.stdout
    checked(["codesign","--force","--sign","-","--options","runtime","--timestamp=none","--entitlements",str(root/"Vane.entitlements"),str(app)],"sign.log")
    checked(["codesign","--verify","--deep","--strict",str(app)],"verify.log")
    checked(["codesign","-dvvv","--entitlements",":-",str(app)],"signature.log")
    checked(["otool","-L",str(executable)],"linked-images.log")
    provenance={"head":subprocess.check_output(["git","rev-parse","HEAD"],cwd=root).decode().strip(),
                "sourceFingerprint":fingerprint,"binarySHA256":hashlib.sha256(binary.read_bytes()).hexdigest(),
                "signedExecutableSHA256":hashlib.sha256(executable.read_bytes()).hexdigest(),
                "signing":"ad-hoc sandboxed Hardened Runtime; not Developer ID/notarized release acceptance",
                "sourcePin":SOURCE_PIN,"laterSourcePin":LATER_PIN,
                "mode":"prepare-namespace" if args.prepare_namespace else "namespace-regression" if namespace_only else "prepare-only" if prepare_only else "one-capability"}
    (evidence/"provenance.json").write_text(json.dumps(provenance,indent=2)+"\n")
    if prepare_only:
        print("Prepared signed "+("namespace" if namespace_only else "capability")+" fixture; no process, store or native/UI probe launched")
        return 0
    spec=importlib.util.spec_from_file_location("owned_native",root/"scripts/run-native-tests.py")
    native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
    environment={key:os.environ[key] for key in ("HOME","PATH","TMPDIR","USER","LOGNAME","LANG") if key in os.environ}
    environment["VANE_DATA_DIR"]=str(data)
    identities=[]
    def interrupted(signum, _frame):
        raise InterruptedError("native capability driver interrupted by signal "+str(signum))
    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    def launch(command,label,timeout):
        # Admission and launch share this flow: a failed guard cannot fall through.
        snapshot=subprocess.check_output(["ps","-axo","pid=,ppid=,command="]).decode()
        (evidence/(label+"-preflight.txt")).write_text(snapshot)
        admit_native_processes(snapshot,os.getpid())
        with (evidence/(label+".log")).open("wb") as output:
            record={"phase":label,"ownedLaunchExited":False}
            host=None
            def save(): (evidence/"ownership.json").write_text(json.dumps({"hosts":identities},indent=2)+"\n")
            def body(process):
                nonlocal host
                record["pid"]=process.pid
                identities.append(record)
                save()
                host=capture_launch_identity(process,native.process_identity,time.sleep,time.monotonic)
                if host is None:raise ValueError("host exited before kernel launch identity could be captured")
                record["host"]=host;save()
                if host["path"]!=str(executable.resolve()):raise ValueError("owned launch executable mismatch")
                try:code=process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    stop_owned(host,lambda pid: observed_identity(process,pid),os.kill,time.sleep,time.monotonic)
                    process.wait(timeout=5);code=124
                record["code"]=code
                return code
            def observed_identity(process,pid):
                # Reap this direct child before querying libproc. Never signal an
                # exited child whose PID might subsequently be recycled.
                if process.poll() is not None:return None
                return native.process_identity(pid)
            def retire(process):
                nonlocal host
                # Preserve every Popen immediately, including metadata/capture
                # failure. Never start cleanup while an earlier app may remain.
                record["pid"]=process.pid
                if record not in identities:identities.append(record)
                if host is None and process.poll() is None:
                    try:
                        host=capture_launch_identity(process,native.process_identity,time.sleep,time.monotonic)
                        if host is not None:record["host"]=host
                    except Exception as error:record["identityError"]=str(error)
                if process.poll() is None:
                    if host is not None and host["path"]==str(executable.resolve()):
                        try:stop_owned(host,lambda pid: observed_identity(process,pid),os.kill,time.sleep,time.monotonic)
                        except Exception as error:record["retirementError"]=str(error)
                    try:process.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:record["retirementError"]="unverified or unretired host remains; cleanup blocked"
                if process.poll() is not None:
                    record["nativeExit"]=process.returncode
                    observed=native.process_identity(process.pid)
                    record["observed"]=observed
                    record["ownedLaunchExited"]=(host is None or observed is None or observed["start"]!=host["start"])
                try:save()
                except Exception:
                    print("OWNED LAUNCH evidence write failed: "+json.dumps(record,sort_keys=True),file=sys.stderr,flush=True)
                    raise
            code=owned_launch(lambda:subprocess.Popen([str(executable),command],env=environment,stdout=output,stderr=subprocess.STDOUT),body,retire)
            if namespace_only and host is not None and (code<0 or code==124):collect_owned_crashes(host,bundle_id,evidence,label)
            return code
    primary=1;cleanup=1;classification="failed";creation=None
    try:
        if namespace_only:
            primary=launch("namespace-store-create","primary",25)
            creation=read_json(data/"namespace-create-report.json")
            if primary!=0 or creation.get("result")!="created":raise ValueError("namespace creation failed")
        else:
            primary=launch("worker-client-capability","primary",75)
            report=read_json(data/"capability-report.json");verdict=read_json(data/"identity-verdict.json")
            classification=validate_report(report,claim,verdict)
            expected={"observed":0,"failed":1,"unavailable":3}[classification]
            if primary!=expected:raise ValueError("native exit did not match strict report classification")
    except Exception as error:
        (evidence/"validation-error.txt").write_text(str(error)+"\n");primary=1;classification="failed"
    finally:
        if all(item.get("ownedLaunchExited") is True for item in identities):
            try:
                cleanup=launch("namespace-store-cleanup" if namespace_only else "worker-client-capability-cleanup","cleanup",25)
                if namespace_only:
                    result=read_json(data/"namespace-cleanup-report.json")
                    classification=validate_namespace_pair(creation,result,claim,identities)
                    if classification!="retired" or primary!=0:raise ValueError("namespace admission/retirement qualification failed")
                else:
                    result=read_json(data/"cleanup-report.json")
                    if result!={"namespace":namespace,"storeID":claim["storeID"],"retired":True} or type(result.get("retired")) is not bool:
                        raise ValueError("exact named-store absence not verified")
                if cleanup:raise ValueError("cleanup process failed")
            except Exception as error:
                (evidence/"cleanup-error.txt").write_text(str(error)+"\n");cleanup=1
                if namespace_only:classification="failed"
        shutil.copytree(data,evidence/"data")
        (evidence/"result.json").write_text(json.dumps({"primary":primary,"cleanup":cleanup,"classification":classification,
            "capabilityOnly":not namespace_only,"namespaceRegression":namespace_only,"uaProbeRun":not namespace_only,
            "uaIssueFixed":False,"ownedHostsExited":all(x.get("ownedLaunchExited") is True for x in identities)},indent=2)+"\n")
        if cleanup==0 and (data/"capability-claim.json").read_text()==json.dumps(claim,indent=2)+"\n":shutil.rmtree(data)
    print("Namespace regression" if namespace_only else "Capability result",classification,"primary",primary,"cleanup",cleanup,"(no UA repair claim)")
    return primary or cleanup


if __name__ == "__main__":
    raise SystemExit(main())
