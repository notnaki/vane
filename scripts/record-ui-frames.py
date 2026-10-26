#!/usr/bin/env python3
"""Record original UI frame events for one exactly identified running test app.

Requires Xcode and a logged-in macOS desktop. Start interacting only after the
RECORDING_STARTED line. Ctrl-C stops acquisition and waits for the saved trace;
it never quits the target app. Keep other builds/profilers stopped for timings.
Do not use a ring buffer: it can discard raw events needed for tail percentiles.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def start_recording(command, log):
    # Terminal Ctrl-C must reach this parent alone. Otherwise xctrace receives
    # the terminal's SIGINT and then a second forwarded interrupt before its
    # buffered "Stopping recording" message becomes visible, corrupting save.
    return subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)


def finish_recording(process, identity, log, process_identity):
    if process.poll() is not None:
        return
    if process_identity(process.pid) != identity:
        raise RuntimeError("recorder launch identity changed")
    finalizing = any(x in log.read_text() for x in
                     ("Reached specified time limit", "Stopping recording", "Saving output"))
    if not finalizing:
        process.send_signal(signal.SIGINT)
    # Saving a full trace can outlast acquisition. Killing it after an arbitrary
    # deadline destroys the data needed to include the slowest frames.
    process.wait()


def export_tables(trace, output):
    """Discover raw tables by their attributes, never unstable numeric indices."""
    subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc",
                    "--output", str(output / "toc.xml")], check=True)
    tables = ET.parse(output / "toc.xml").findall(".//run/data/table")
    required = {'"0x31,0xca"': "client", '"0x31,0xd0"': "render",
                '"0x31,0xd1"': "display"}
    selected = {}
    for index, table in enumerate(tables, 1):
        schema, codes = table.get("schema"), table.get("codes")
        name = required.get(codes) if schema == "kdebug" else (
            "clock" if schema == "time-info" else None)
        if name is None:
            continue
        if name in selected:
            raise ValueError(f"ambiguous raw table: {name}")
        selected[name] = dict(table.attrib)
        subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace),
                        "--xpath", f'/trace-toc/run[@number="1"]/data/table[{index}]',
                        "--output", str(output / (name + ".xml"))], check=True)
    if set(selected) != {"client", "render", "display", "clock"}:
        raise ValueError("trace lacks required raw event tables")
    write_json(output / "tables.json", selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New private evidence directory")
    parser.add_argument("--seconds", type=int, default=45)
    args = parser.parse_args()
    if not 2 <= args.seconds <= 300:
        parser.error("--seconds must be between 2 and 300")
    spec = importlib.util.spec_from_file_location("native_runner", ROOT / "run-native-tests.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    target = native.process_identity(args.pid)
    executable = args.executable.resolve(strict=True)
    if target is None or target["path"] != str(executable):
        parser.error("PID does not belong to the specified executable")
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package = ROOT / "fixtures/ui-frame-events.instrpkg"
    provenance = {"target": target, "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                  "instrumentSHA256": hashlib.sha256(package.read_bytes()).hexdigest(),
                  "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True),
                  "powerBefore": subprocess.check_output(["pmset", "-g", "batt"], text=True),
                  "startedAt": time.time(), "fullRecording": True}
    write_json(output / "recording.json", provenance)
    distribution = output / "UIFrames.instrdst"
    with (output / "instrument-build.log").open("w") as log:
        subprocess.run(["xcrun", "instrumentbuilder", "-o", str(distribution), str(package)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    key = "io.vane.ui-recording." + uuid.uuid4().hex
    trace = output / "capture.trace"
    command = [subprocess.check_output(["xcrun", "--find", "xctrace"], text=True).strip(),
               "record", "--package", str(distribution), "--instrument", "Vane UI Frame Events",
               "--all-processes", "--notify-tracing-started", key,
               "--time-limit", str(args.seconds) + "s", "--output", str(trace)]
    stop_requested = False
    def request_stop(_signum, _frame):
        nonlocal stop_requested
        stop_requested = True
    previous = {}
    listener = None
    process = None
    identity = None
    try:
        for sig in (signal.SIGINT, signal.SIGTERM):
            previous[sig] = signal.signal(sig, request_stop)
        listener = subprocess.Popen(["/usr/bin/notifyutil", "-1", key], stdout=subprocess.DEVNULL)
        with (output / "record.log").open("w") as log:
            process = start_recording(command, log)
            identity = native.process_identity(process.pid)
            provenance.update(recorder=identity, command=command)
            write_json(output / "recording.json", provenance)
            deadline = time.monotonic() + 30
            while listener.poll() is None and process.poll() is None and time.monotonic() < deadline:
                if stop_requested:
                    break
                time.sleep(0.05)
            admitted = listener.poll() == 0 and process.poll() is None and not stop_requested
            provenance["tracingStartedConfirmed"] = admitted
            write_json(output / "recording.json", provenance)
            if admitted:
                print(f"RECORDING_STARTED pid={args.pid} output={output}", flush=True)
            else:
                stop_requested = True
            stopped = False
            while process.poll() is None:
                if stop_requested and not stopped:
                    # A second interrupt during finalization can corrupt an otherwise
                    # complete trace. Allow xctrace to finish saving without a deadline.
                    finish_recording(process, identity, output / "record.log", native.process_identity)
                    stopped = True
                time.sleep(0.1)
            provenance.update(exitCode=process.wait(), recorderExited=native.process_identity(process.pid) is None,
                              targetAfter=native.process_identity(args.pid), finishedAt=time.time(),
                              powerAfter=subprocess.check_output(["pmset", "-g", "batt"], text=True))
            write_json(output / "recording.json", provenance)
        if provenance["exitCode"] != 0 or not admitted:
            raise RuntimeError("recording did not finish successfully; inspect record.log")
        export_tables(trace, output)
        if provenance["targetAfter"] != target:
            raise RuntimeError("target app launch changed during recording; timings are invalid")
        print("SAVED_AND_EXPORTED " + str(output), flush=True)
    finally:
        try:
            if process is not None and process.poll() is None:
                finish_recording(process, identity, output / "record.log", native.process_identity)
        finally:
            if listener is not None:
                if listener.poll() is None:
                    listener.terminate()
                listener.wait()
            for sig, handler in previous.items():
                signal.signal(sig, handler)


if __name__ == "__main__":
    main()
