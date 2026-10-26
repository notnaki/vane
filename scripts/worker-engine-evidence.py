#!/usr/bin/env python3
"""Read-only images from an app-owned service-worker candidate after UA comparison.

Worker attribution remains conditional on WebKit's app-scoped process registry
and continuity. Thread presence alone does not bind a worker to a context.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

PREFIX = b"UA WORKER ENGINE REQUEST "
CORE = {"WebKit", "WebCore", "JavaScriptCore"}
STAGED = Path("/System/Cryptexes/App/System/Library/StagedFrameworks/Safari")
HELPER = "/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

def thread_names(pid):
    """Bounded kernel thread-name snapshot of an already verified app child."""
    class ThreadInfo(ctypes.Structure):
        _fields_ = [("user", ctypes.c_uint64), ("system", ctypes.c_uint64),
                    ("scheduling", ctypes.c_int32 * 8), ("name", ctypes.c_char * 64)]
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    query = library.proc_pidinfo
    query.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    query.restype = ctypes.c_int
    identifiers = (ctypes.c_uint64 * 256)()
    size = query(pid, 6, 0, identifiers, ctypes.sizeof(identifiers))
    if size <= 0 or size >= ctypes.sizeof(identifiers) or size % 8:
        raise OSError("Thread inventory unavailable or exceeds capture bound")
    names = []
    for identifier in identifiers[:size // 8]:
        info = ThreadInfo()
        if query(pid, 5, identifier, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            raise OSError("Thread identity changed or unavailable")
        names.append(info.name.decode(errors="replace"))
    return names

def parse_request(output, host):
    lines = [line[len(PREFIX):] for line in output.splitlines(keepends=True)
             if line.startswith(PREFIX) and line.endswith(b"\n")]
    if not lines: return None
    if len(lines) != 1 or len(lines[0]) > 8192: raise ValueError("Missing unique bounded process request")
    record = json.loads(lines[0])
    if not isinstance(record, dict) or set(record) != {"hostPID", "pid", "pidStart", "nonce", "context", "stage", "manifestVersion"}:
        raise ValueError("Malformed process request")
    if (not host or type(record["hostPID"]) is not int or record["hostPID"] != host["pid"]
            or type(record["pid"]) is not int or not 1 < record["pid"] <= 2147483647 or record["pid"] == host["pid"]
            or type(record["pidStart"]) is not int or not 0 < record["pidStart"] < 2**63
            or type(record["manifestVersion"]) is not int or record["manifestVersion"] != 3
            or not isinstance(record["stage"], str) or record["stage"] not in {"safari-mv3", "custom-mv3", "safari-after-custom-mv3"}):
        raise ValueError("Process request is not bound to the actual MV3 app")
    for key in ("nonce", "context"):
        if not isinstance(record[key], str) or uuid.UUID(record[key]).int == 0 or str(uuid.UUID(record[key])).lower() != record[key].lower():
            raise ValueError("Invalid request identity")
    return record

def parse_sample(text, worker):
    if not re.search(r"(?m)^Process:\s+com\.apple\.WebKit\.WebContent \[" + str(worker["pid"]) + r"\]\s*$", text):
        raise ValueError("Sample PID does not match requested background owner")
    path = re.search(r"(?m)^Path:\s+(/.+)$", text)
    if not path or Path(path[1].strip()).resolve() != Path(worker["path"]).resolve():
        raise ValueError("Sample executable does not match actual process identity")
    # SWServerWorker::workerThreadMode uses UseMainThread for page-backed
    # workers, including extension backgrounds. A separate named thread is
    # therefore not a liveness/ownership requirement. Native page/process
    # binding and external kernel identity continuity establish attribution.
    section = text.split("Binary Images:", 1)
    if len(section) != 2: raise ValueError("No actual loaded image table")
    images = {}
    pattern = r"(?m)^\s*0x[0-9a-fA-F]+\s*-\s*0x[0-9a-fA-F]+\s+.+?\(([^)\n]+)\)\s+<([0-9A-Fa-f-]{36})>\s+(/.+)$"
    for version, identity, name in re.findall(pattern, section[1]):
        path = Path(name.strip()); leaf = path.name
        if leaf not in CORE: continue
        version = version.split(" - ")[-1]
        if (leaf in images or not str(path).startswith("/System/")
                or not any(parent.name == leaf + ".framework" for parent in path.parents)
                or not re.fullmatch(r"\d+(?:\.\d+)+", version) or uuid.UUID(identity).int == 0):
            raise ValueError("Missing, duplicate or malformed actual core image")
        images[leaf] = {"path": str(path), "uuid": str(uuid.UUID(identity)), "version": version}
    if set(images) != CORE: raise ValueError("All three actual core images are required")
    return images

def validate_staged_images(images):
    if set(images) != CORE or any(not Path(item["path"]).resolve().is_relative_to(STAGED.resolve())
            or not re.fullmatch(r"\d*625\.\d+(?:\.\d+)+", item["version"]) for item in images.values()):
        raise ValueError("Observed background owner uses a different or mixed engine; raw evidence retained")

class WorkerEngineCapture:
    def __init__(self, data, evidence, invoke=subprocess.run, threads=thread_names):
        self.data, self.evidence, self.invoke = data, evidence, invoke
        self.threads = threads
        self.thread = None
        self.seen = False

    def __call__(self, output, host, identity):
        if self.seen: return
        try: request = parse_request(output, host)
        except (ValueError, TypeError, KeyError) as error:
            self.seen = True
            self.write({"status": "unavailable", "reason": str(error)})
            return
        if request is None: return
        self.seen = True
        self.thread = threading.Thread(target=self.capture, args=(request, host, identity), name="background-owner-images")
        self.thread.start()  # Never block the owner's timeout/cancellation loop.

    def write(self, record):
        (self.evidence / "worker-engine.json").write_text(json.dumps(record, sort_keys=True) + "\n")

    def capture(self, request, host, identity):
        result = {"status": "unavailable", "request": request, "app": host,
                  "attribution": "app-owned-service-worker-candidate; context attribution conditional"}
        # Cold staged frameworks can take >5 seconds to symbolicate on hosted
        # macOS. This budget applies only after the original UA comparison.
        deadline = time.monotonic() + 26
        try:
            if identity(host["pid"]) != host: raise ValueError("App process identity changed")
            worker = identity(request["pid"])
            if (not worker or type(worker.get("pid")) is not int or worker["pid"] != request["pid"]
                    or type(worker.get("start")) is not int or worker["start"] != request["pidStart"]
                    or not isinstance(worker.get("path"), str)
                    or not worker["path"].startswith("/System/") or not worker["path"].endswith(HELPER)):
                raise ValueError("Requested process is not an Apple WebContent executable")
            result["worker"] = worker
            try: result["kernelThreadNames"] = self.threads(worker["pid"])
            except OSError as error: result["kernelThreadNamesUnavailable"] = str(error)
            if identity(host["pid"]) != host or identity(worker["pid"]) != worker:
                raise ValueError("App or background-owner identity changed during thread inventory")
            path = self.evidence / "worker-engine.sample.txt"
            command = ["/usr/bin/sample", str(worker["pid"]), "1", "1", "-mayDie", "-file", str(path)]
            sampled = self.invoke(command, capture_output=True, text=True, timeout=min(25, max(.01, deadline - time.monotonic())))
            (self.evidence / "worker-engine-tool.log").write_text((sampled.stdout + sampled.stderr)[-65536:])
            if identity(host["pid"]) != host or identity(worker["pid"]) != worker:
                raise ValueError("App or background-owner identity changed during sampling")
            if time.monotonic() >= deadline: raise ValueError("Total capture budget exceeded")
            if sampled.returncode != 0: raise ValueError("Read-only sampling unavailable")
            if not path.is_file() or path.is_symlink() or path.stat().st_size > 1048576:
                raise ValueError("Missing or oversized sample")
            result["images"] = parse_sample(path.read_text(errors="replace"), worker)
            if time.monotonic() >= deadline: raise ValueError("Total capture budget exceeded")
            result["identityVerifiedBeforeAndAfter"] = True
            result["status"] = "captured"
        except subprocess.TimeoutExpired as error:
            def decoded(value):
                return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
            (self.evidence / "worker-engine-tool.log").write_text((decoded(error.stdout) + decoded(error.stderr))[-65536:])
            result["reason"] = str(error)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result["reason"] = str(error)
        finally:
            try:
                descriptor = os.open(self.data / ("ua-worker-engine-" + request["nonce"] + ".done"),
                                     os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                os.close(descriptor)
            except OSError as error:
                result.update(status="unavailable", reason="Diagnostic hold acknowledgement failed: " + str(error))
            self.write(result)

    def close(self):
        if self.thread:
            self.thread.join(timeout=27)
            if self.thread.is_alive(): raise ValueError("Bounded capture thread did not finish")

def check_captures(directory, expect_staged=False):
    trials = sorted(directory.glob("trial-*"))
    if not trials: raise ValueError("No post-comparison background-owner evidence")
    for trial in trials:
        path = trial / "worker-engine.json"
        if not path.is_file() or not (trial / "primary.log").is_file():
            raise ValueError("Missing capture for executed trial: " + trial.name)
        record = json.loads(path.read_text())
        if record.get("status") != "captured": raise ValueError("Unavailable background-owner evidence: " + str(record.get("reason")))
        images = parse_sample(path.with_name("worker-engine.sample.txt").read_text(), record["worker"])
        if images != record.get("images"): raise ValueError("Recorded images differ from preserved sample")
        if record.get("identityVerifiedBeforeAndAfter") is not True: raise ValueError("Process identity continuity unverified")
        native_output = path.with_name("primary.log").read_bytes()
        if parse_request(native_output, record["app"]) != record["request"]:
            raise ValueError("Capture request differs from native primary output")
        if record["worker"].get("pid") != record["request"]["pid"]:
            raise ValueError("Captured process differs from requested process")
        lines = [line.removeprefix("UA BACKGROUND OWNER CONTINUITY ") for line in native_output.decode().splitlines()
                 if line.startswith("UA BACKGROUND OWNER CONTINUITY ")]
        if len(lines) != 1: raise ValueError("Missing unique native background-owner continuity record")
        continuity = json.loads(lines[0]); request = record["request"]
        if (continuity.get("nonce") != request["nonce"] or continuity.get("context") != request["context"]
                or continuity.get("pidBefore") != request["pid"] or continuity.get("pidAfter") != request["pid"]
                or any(continuity.get(key) is not True for key in ("acknowledged", "contextStillLoaded", "sameBackgroundView"))):
            raise ValueError("Native background-owner PID/context continuity unverified")
        print("OBSERVED background-owner images " + json.dumps({"trial": path.parent.name, "images": images}, sort_keys=True))
        if expect_staged:
            validate_staged_images(images)
            for name, item in images.items():
                image = Path(item["path"])
                framework = next(parent for parent in image.parents if parent.name == name + ".framework")
                subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple", str(framework)], check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                dump = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(image)], check=True, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                if item["uuid"].lower() not in dump.stdout.lower(): raise ValueError("Actual loaded UUID does not match Apple installed image")
    print("Background-owner capture verified; worker attribution remains conditional on process selection and continuity")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--expect-staged", action="store_true")
    options = parser.parse_args()
    try: check_captures(options.directory, options.expect_staged)
    except (OSError, ValueError, subprocess.SubprocessError) as error: raise SystemExit("UNAVAILABLE OR DIFFERENT ENGINE: " + str(error))
