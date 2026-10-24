#!/usr/bin/env python3
"""Collect bounded ReportCrash output belonging to this job's Swift test bundle."""

import json
import os
from pathlib import Path
import re
import stat
import time
import uuid

MAX_REPORT_BYTES = 1024 * 1024
MAX_REPORTS = 3
MAX_LOG_BYTES = 64 * 1024


def ips_report(text):
    # Modern .ips files have a metadata JSON line followed by the report JSON.
    return json.loads(text.split("\n", 1)[1])


def collect(report_dirs, started, workspace, destination):
    reports = []
    for directory in report_dirs:
        for path in directory.glob("*"):
            try:
                info = path.lstat()
            except OSError:
                continue
            if (stat.S_ISREG(info.st_mode) and info.st_mtime >= started
                    and path.suffix in (".ips", ".crash")
                    and path.stem.startswith(("xctest_", "xctest-", "VanePackageTests_", "VanePackageTests-"))
                    and info.st_size <= MAX_REPORT_BYTES):
                reports.append((info.st_mtime, path))
    saved = []
    for _, path in sorted(reports, reverse=True)[:20]:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as report:
                data = report.read(MAX_REPORT_BYTES + 1)
        except OSError:
            continue
        if len(data) > MAX_REPORT_BYTES:
            continue
        text = data.decode("utf-8", errors="replace")
        # xctest itself lives in Xcode: the loaded test bundle identifies our runner.
        bundle = str(workspace / ".build") + "/"
        if path.suffix == ".ips":
            try:
                images = ips_report(text).get("usedImages", [])
                owned = any(image.get("path", "").startswith(bundle)
                            and "/VanePackageTests.xctest/" in image.get("path", "")
                            for image in images)
            except (ValueError, IndexError, TypeError, AttributeError):
                continue  # ReportCrash may still be writing the file; try again later.
        else:
            owned = re.search(re.escape(bundle) + r'[^"\n]*/VanePackageTests\.xctest(?:[/"\s])', text)
        if not owned:
            continue
        destination.mkdir(parents=True, exist_ok=True)
        output = destination / f"{len(saved) + 1}-{path.name}"
        output.write_bytes(data)
        saved.append(output)
        if len(saved) == MAX_REPORTS:
            break
    return saved


def log_report(path):
    text = path.read_text(errors="replace")
    if path.suffix == ".ips":
        try:
            report = ips_report(text)
            summary = {key: report[key] for key in
                       ("procName", "procPath", "exception", "termination", "faultingThread")
                       if key in report}
            if "asi" in report:
                summary["applicationSpecificInformation"] = json.dumps(report["asi"])[:4096]
            if "lastExceptionBacktrace" in report:
                summary["lastExceptionBacktrace"] = report["lastExceptionBacktrace"]
            threads = report.get("threads", [])
            faulting = report.get("faultingThread")
            summary["crashedThreads"] = [thread for index, thread in enumerate(threads)
                                         if thread.get("triggered") or index == faulting]
            summary["usedImages"] = report.get("usedImages", [])
            text = json.dumps(summary, indent=2)
        except (ValueError, IndexError, TypeError):
            pass  # Older ReportCrash formats remain useful as bounded plain text.
    token = uuid.uuid4().hex
    print(f"Crash report: {path.name}\n::stop-commands::{token}", flush=True)
    print(text.encode("utf-8")[:MAX_LOG_BYTES].decode("utf-8", errors="replace"), flush=True)
    print(f"::{token}::", flush=True)


if __name__ == "__main__":
    temporary = Path(os.environ["RUNNER_TEMP"])
    started = (temporary / "vane-swift-tests-start").stat().st_mtime
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    destination = temporary / "vane-xctest-crash-reports"
    directories = (Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports"))
    # ReportCrash can finish writing after swift test has already exited.
    for attempt in range(11):
        saved = collect(directories, started, workspace, destination)
        if saved:
            break
        if attempt < 10:
            time.sleep(1)
    for path in saved:
        log_report(path)
    if not saved:
        print("No recent crash report containing this workspace's VanePackageTests bundle was found.")
