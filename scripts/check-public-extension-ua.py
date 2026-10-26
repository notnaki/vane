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
SCENARIOS = {"ordered": STAGES, "fresh-mv3": ("fresh Safari MV3",)}


def records_from_output(output):
    records = []
    for line in output.decode("utf-8", errors="replace").splitlines():
        if not line.startswith("{"): continue
        try: record = json.loads(line)
        except json.JSONDecodeError: raise ValueError("Malformed JSON record") from None
        if not isinstance(record, dict) or record.get("event") not in {
                "launch", "observation", "failure", "summary", "retirement", "launch-admission-failure", "cleanup-timeout"}:
            raise ValueError("Unknown probe record")
        records.append(record)
    return records


def validate_launch_record(launch):
    if not isinstance(launch, dict) or launch.get("event") != "launch": raise ValueError("No real launch admission record")
    if launch.get("arm") != ARM or launch.get("finishedLaunching") is not True or launch.get("appRunning") is not True:
        raise ValueError("Public normal-application launch was not verified")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*\+?", str(launch.get("WebKit", ""))) or not launch.get("OS"):
        raise ValueError("Concrete system WebKit/OS metadata is required")
    try: uuid.UUID(launch["ownedDataStoreID"])
    except (KeyError, ValueError, TypeError, AttributeError): raise ValueError("Missing owned named-store UUID") from None
    return launch


def validate_probe_output(output, status, scenario="ordered"):
    stages = SCENARIOS[scenario]
    records = records_from_output(output)
    launch = validate_launch_record(records[0] if records else None)
    if launch.get("scenario", "ordered") != scenario:
        raise ValueError("Launch scenario did not match the requested control")
    observations = []
    nonces = set()
    mismatch = False
    for record in records[1:]:
        if record["event"] != "observation": break
        index = len(observations)
        if index >= len(stages) or record.get("stage") != stages[index] or record.get("arm") != ARM:
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
        if worker.get("scheme") != "webkit-extension:" or worker.get("version") != ("2" if scenario == "ordered" and index == 0 else "3"):
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
        if len(observations) != len(stages) or len(tail) != 1:
            raise ValueError("Missing requested stage coverage or final summary")
        completed = len(stages)
    summary = tail[-1]
    if summary.get("event") != "summary" or summary.get("completedStages") != completed:
        raise ValueError("Missing or inconsistent final stage count")
    if summary.get("mismatchOrHarnessFailure") is not mismatch or summary.get("backendRetirementVerified") is not False:
        raise ValueError("Invalid failure/retirement summary")
    cleanup = summary.get("ownedStoreRemovalCallbackSucceeded") is True
    deferred = summary.get("storeRemovalDeferredToPostExit", False)
    if not isinstance(deferred, bool) or (deferred and summary.get("ownedStoreRemovalCallbackSucceeded") is not False):
        raise ValueError("Invalid deferred store retirement")
    if not mismatch and (status != 0 or not (cleanup or deferred)): raise ValueError("App exit or owned-store cleanup was not successful")
    return {"result": "PUBLIC_UA_MISMATCH_OBSERVED" if mismatch else "PUBLIC_ARM_PRIMARY_PASSED" if deferred else "PUBLIC_ARM_SAMPLE_PASSED",
            "completedStages": completed, "observedStages": len(observations), "ownedStoreRemovalCallbackSucceeded": cleanup,
            "storeRemovalDeferredToPostExit": deferred,
            "backendRetirementVerified": False, "ownedDataStoreID": launch["ownedDataStoreID"]}


def validate_retirement_output(output, status, store_id):
    records = records_from_output(output)
    if status != 0 or len(records) != 1 or records[0].get("event") != "retirement":
        raise ValueError("Missing successful post-exit retirement callback")
    record = records[0]
    if record.get("ownedDataStoreID") != store_id or record.get("ownedStoreRemovalCallbackSucceeded") is not True:
        raise ValueError("Post-exit retirement did not remove the exact launch store")
    if record.get("backendRetirementVerified") is not False:
        raise ValueError("Post-exit retirement cannot attest backend-process exit")


def run_public_mode(bundle, evidence_dir, scenario="ordered"):
    if scenario not in SCENARIOS: raise ValueError("Unknown public probe scenario")
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
        command = [str(executable)] + (["--fresh-mv3"] if scenario == "fresh-mv3" else [])
        status, exited, output = owned.run_ua_process(command, environment, 90, trial_logs / "primary.log", interrupted)
        result = {"trial": number, "processStatus": status, "ownedAppExitVerified": exited,
                  "scenario": scenario, "result": "HARNESS_FAILED_OR_UNAVAILABLE", "backendRetirementVerified": False}
        retirement_store = None
        try:
            if not exited: raise ValueError("Exact owned app exit could not be verified; cleanup is unverified")
            records = records_from_output(output)
            launch = validate_launch_record(records[0] if records else None)
            if any(record.get("event") == "summary" and record.get("storeRemovalDeferredToPostExit") is True for record in records):
                retirement_store = launch["ownedDataStoreID"]
            result.update(validate_probe_output(output, status, scenario=scenario))
        except ValueError as error:
            result["reason"] = str(error)
            status = status or 1
        if retirement_store is not None:
            result["ownedStoreRemovalCallbackSucceeded"] = False
            try:
                cleanup_status, cleanup_exited, cleanup_output = owned.run_ua_process(
                    [str(executable), "--retire-store", retirement_store], environment, 20, trial_logs / "cleanup.log", interrupted)
                result.update(cleanupProcessStatus=cleanup_status, ownedCleanupExitVerified=cleanup_exited)
                if not cleanup_exited: raise ValueError("Exact cleanup app exit could not be verified")
                validate_retirement_output(cleanup_output, cleanup_status, retirement_store)
                result["ownedStoreRemovalCallbackSucceeded"] = True
                if result["result"] == "PUBLIC_ARM_PRIMARY_PASSED": result["result"] = "PUBLIC_ARM_SAMPLE_PASSED"
            except (OSError, ValueError) as error:
                result["cleanupReason"] = str(error)
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
    parser.add_argument("--scenario", choices=SCENARIOS, default="ordered")
    options = parser.parse_args()
    try: return run_public_mode(options.bundle, options.evidence_dir, scenario=options.scenario)
    except (OSError, ValueError) as error:
        print(f"FAIL public reduction: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__": raise SystemExit(main())
