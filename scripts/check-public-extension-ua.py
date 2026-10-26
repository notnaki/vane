#!/usr/bin/env python3
"""Public-only reduction adapter; reuse the independently reviewed owned-process runner.

No Vane product/SPI/observer path is invoked. A finite passing sample is inconclusive.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sys
import uuid

spec = importlib.util.spec_from_file_location("owned_extension_ua", Path(__file__).with_name("check-extension-ua.py"))
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)

ARM = "public-suffix-only"
SUFFIX = "Version/26.6.2 Safari/605.1.15"
STAGES = ("Safari MV2", "Safari MV3 after MV2", "second Safari MV3", "third Safari MV3")


def records_from_output(output):
    records = []
    for line in output.decode("utf-8", errors="replace").splitlines():
        if not line.startswith("{"): continue
        try: record = json.loads(line)
        except json.JSONDecodeError: raise ValueError("Malformed JSON record") from None
        if not isinstance(record, dict) or record.get("event") not in {
                "launch", "observation", "failure", "summary", "launch-admission-failure", "cleanup-timeout"}:
            raise ValueError("Unknown probe record")
        records.append(record)
    return records


def validate_probe_output(output, status):
    records = records_from_output(output)
    if not records or records[0].get("event") != "launch": raise ValueError("No real launch admission record")
    launch = records[0]
    if launch.get("arm") != ARM or launch.get("finishedLaunching") is not True or launch.get("appRunning") is not True:
        raise ValueError("Public normal-application launch was not verified")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*\+?", str(launch.get("WebKit", ""))) or not launch.get("OS"):
        raise ValueError("Concrete system WebKit/OS metadata is required")
    try: uuid.UUID(launch["ownedDataStoreID"])
    except (KeyError, ValueError, TypeError, AttributeError): raise ValueError("Missing owned named-store UUID") from None
    observations = []
    nonces = set()
    mismatch = False
    for record in records[1:]:
        if record["event"] != "observation": break
        index = len(observations)
        if index >= len(STAGES) or record.get("stage") != STAGES[index] or record.get("arm") != ARM:
            raise ValueError("Missing, duplicated, reordered or unknown stage")
        if record.get("boundToCurrentContext") is not True or record.get("popupPoolStoreAndControllerMatch") is not True:
            raise ValueError("Current-context or pool/store/controller binding failed")
        identity = record.get("identity")
        if not isinstance(identity, dict) or not isinstance(identity.get("worker"), dict): raise ValueError("Missing identity payload")
        worker = identity["worker"]
        nonce = identity.get("nonce")
        try: uuid.UUID(nonce)
        except (ValueError, TypeError, AttributeError): raise ValueError("Invalid stage nonce") from None
        if nonce in nonces: raise ValueError("Reused stage nonce")
        nonces.add(nonce)
        if any(payload.get(key) != nonce for payload in (identity, worker) for key in ("nonce", "runtime", "host")):
            raise ValueError("Reply does not belong to current nonce/runtime/origin")
        if worker.get("scheme") != "webkit-extension:" or worker.get("version") != ("2" if index == 0 else "3"):
            raise ValueError("Background scheme/manifest version did not match")
        if any(not isinstance(payload.get(key), str) for payload in (identity, worker) for key in ("startup", "current")):
            raise ValueError("Missing startup/current UA")
        if SUFFIX not in identity["startup"] or identity["current"] != identity["startup"]:
            raise ValueError("Configured popup startup/current control did not match")
        equal = worker["startup"] == identity["startup"] and worker["current"] == identity["startup"]
        if record.get("startupAndCurrentMatch") is not equal:
            raise ValueError("Native UA result disagrees with recorded startup/current values")
        observations.append(record)
        if not equal:
            mismatch = True
            break
    tail = records[1 + len(observations):]
    if mismatch:
        if len(tail) != 2 or tail[0].get("event") != "failure" or tail[0].get("reason") != "Worker/popup startup or current identity mismatch":
            raise ValueError("Mismatch did not stop at its original native failure")
        if status == 0: raise ValueError("Mismatch with zero process exit")
        completed = len(observations) - 1
    else:
        if len(observations) != len(STAGES) or len(tail) != 1:
            raise ValueError("Missing original four-stage coverage or final summary")
        completed = len(STAGES)
    summary = tail[-1]
    if summary.get("event") != "summary" or summary.get("completedStages") != completed:
        raise ValueError("Missing or inconsistent final stage count")
    if summary.get("mismatchOrHarnessFailure") is not mismatch or summary.get("backendRetirementVerified") is not False:
        raise ValueError("Invalid failure/retirement summary")
    cleanup = summary.get("ownedStoreRemovalCallbackSucceeded") is True
    if not mismatch and (status != 0 or not cleanup): raise ValueError("App exit or owned-store cleanup was not successful")
    return {"result": "PUBLIC_UA_MISMATCH_OBSERVED" if mismatch else "PUBLIC_ARM_SAMPLE_PASSED",
            "completedStages": completed, "observedStages": len(observations), "ownedStoreRemovalCallbackSucceeded": cleanup,
            "backendRetirementVerified": False, "ownedDataStoreID": launch["ownedDataStoreID"]}


def run_public_mode(bundle, evidence_dir):
    bundle = bundle.resolve()
    executable = bundle / "Contents/MacOS/WorkerUAProbe"
    if not executable.is_file(): raise ValueError("Built signed public probe executable is required")
    evidence_dir = evidence_dir.resolve()
    evidence_dir.mkdir(mode=0o700)
    interrupted = [None]
    previous = {sig: signal.signal(sig, lambda signum, frame: interrupted.__setitem__(0, signum))
                for sig in (signal.SIGINT, signal.SIGTERM)}
    environment = {name: os.environ[name] for name in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG") if name in os.environ}

    def trial(number):
        if interrupted[0]: return 128 + interrupted[0]
        trial_logs = evidence_dir / f"trial-{number:02d}"
        trial_logs.mkdir(mode=0o700)
        status, exited, output = owned.run_ua_process([str(executable)], environment, 90, trial_logs / "primary.log", interrupted)
        result = {"trial": number, "processStatus": status, "ownedAppExitVerified": exited,
                  "result": "HARNESS_FAILED_OR_UNAVAILABLE", "backendRetirementVerified": False}
        try:
            if not exited: raise ValueError("Exact owned app exit could not be verified; cleanup is unverified")
            result.update(validate_probe_output(output, status))
        except ValueError as error:
            result["reason"] = str(error)
            status = status or 1
        # A mismatch remains a failed trial even if its original store cleanup succeeded.
        if result["result"] != "PUBLIC_ARM_SAMPLE_PASSED": status = status or 1
        (trial_logs / "result.json").write_text(json.dumps(result, sort_keys=True) + "\n")
        print(json.dumps(result, sort_keys=True), flush=True)
        return status

    try: return owned.run_ua_trials(trial, count=8)
    finally:
        for sig, handler in previous.items(): signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    options = parser.parse_args()
    try: return run_public_mode(options.bundle, options.evidence_dir)
    except (OSError, ValueError) as error:
        print(f"FAIL public reduction: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__": raise SystemExit(main())
