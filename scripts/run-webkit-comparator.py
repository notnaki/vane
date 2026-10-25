#!/usr/bin/env python3
"""CI-only comparison against an official, revision-pinned WebKit build archive."""
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

REVISION = "324648@main"
COMMIT = "070ff828ed26b6305dd78575369cdddb79b5411f"
ARCHIVE_URL = f"https://s3-us-west-2.amazonaws.com/minified-archives.webkit.org/mac-tahoe-x86_64-arm64-release/{REVISION}.zip"
ARCHIVE_SIZE = 332339110
ARCHIVE_MD5 = "6d17a7645877eb9e24f04299efc7deb4"  # Official S3 single-part ETag.
ROOT = Path(__file__).resolve().parents[1]
PROBE = "WebKitExtensionUserAgentPolicyProbeTests testFullUserAgentPolicyAgainstPublicBackgroundCallbackControl"
CASES = [
    "ExtensionUserAgentTests " + name for name in (
        "testBrowserAndExtensionPoolsShareOwnershipWithoutSharingProfileStorage",
        "testDefaultSafariIdentityReachesBackgroundAndPopupBeforeTheirScriptsRun",
        "testDevelopChangeUpdatesLiveBackgroundAndRecreatedPopupWithoutChangingAccess",
        "testExplicitCustomIdentitySurvivesHostRestoration",
        "testServiceWorkerIdentityFollowsSelectionWhenSharedPoolIsReused",
    )
] + ["PasswordAutofillTests " + name for name in (
    "testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep",
    "testReplacementUsernameFormCannotReuseExplicitSelection",
)]
# The teardown-only UA case remains in ordinary CI. It unloads immediately and
# offers no live script observation whose service provenance can be established.
FIXTURE_OBSERVATIONS = dict(zip(CASES, (1, 2, 2, 2, 2, 2, 2)))


def case_output(log, case):
    started = f"Test Case '-[VaneTests.{case}]' started."
    passed = f"Test Case '-[VaneTests.{case}]' passed"
    if log.count(started) != 1:
        raise ValueError("missing or repeated case start: " + case)
    start = log.index(started) + len(started)
    end = log.index(passed)
    if start >= end:
        raise ValueError("case evidence is out of order: " + case)
    return log[start:end]


def verify_log(log, status, cases, require_client=True):
    if status != 0 or re.search(r"^\*\*\* Signal [0-9]+: Backtracing", log, re.MULTILINE):
        raise ValueError("native command failed or captured a fatal signal")
    for case in cases:
        if f"Test Case '-[VaneTests.{case}]' passed" not in log:
            raise ValueError("expected case did not pass: " + case)
    observed = re.findall(r"Test Case '-\[VaneTests\.([^\]]+)\]' (?:passed|failed)", log)
    allowed = set(cases) | {"NativeFixtureRetirementTests testRetireManifest"}
    if set(observed) - allowed or any(observed.count(case) != 1 for case in cases):
        raise ValueError("native command did not execute exactly the requested comparator cases")
    for case in cases:
        output = case_output(log, case)
        if case in FIXTURE_OBSERVATIONS:
            scope = "ua-identity" if case.startswith("ExtensionUserAgentTests ") else "password-continuation"
            expected = f"Vane fixture diagnostic: WEBKIT COMPARATOR FIXTURE SERVICES ATTESTED case={case.replace(' ', '/')} scope={scope}"
            markers = [line for line in output.splitlines() if line.startswith("Vane fixture diagnostic: WEBKIT COMPARATOR FIXTURE SERVICES ATTESTED")]
            if markers != [expected] * FIXTURE_OBSERVATIONS[case]:
                raise ValueError("missing live fixture service provenance: " + case)
        elif case != PROBE:
            raise ValueError("case has no comparator fixture provenance contract: " + case)
        if case == PROBE:
            for marker in ("WEBKIT COMPARATOR ATTESTED", "WEBKIT COMPARATOR SERVICES ATTESTED", "WEBKIT COMPARATOR CLIENT ASSOCIATED"):
                if marker not in output:
                    raise ValueError("probe did not attest its own live fixture: " + marker)
    required = ["Native suite primary status=0; cleanup status=0", "WEBKIT COMPARATOR ATTESTED",
                "WEBKIT COMPARATOR SERVICES ATTESTED"]
    if require_client:
        required.append("WEBKIT COMPARATOR CLIENT ASSOCIATED")
    for marker in required:
        if marker not in log:
            raise ValueError("missing comparator evidence: " + marker)


def verify_download(path, size=ARCHIVE_SIZE, digest=ARCHIVE_MD5):
    if path.stat().st_size != size:
        raise ValueError("archive size differs from pinned official artifact")
    actual = hashlib.md5()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            actual.update(chunk)
    if actual.hexdigest() != digest:
        raise ValueError("archive MD5 differs from pinned official single-part ETag")


def archive_product_directory(entries):
    # Official mac archives use ditto --keepParent (normally Release). Resolve
    # the single framework product root from metadata before extracting anything.
    roots = set()
    for entry in entries:
        parts = Path(entry.filename).parts
        if "WebKit.framework" in parts:
            index = parts.index("WebKit.framework")
            if parts[index + 1:] in (("WebKit",), ("Versions", "A", "WebKit")):
                roots.add(Path(*parts[:index]))
    if len(roots) != 1:
        raise ValueError("archive must contain exactly one WebKit framework product root")
    return roots.pop()


def command(args, allow_unsigned=False):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20, check=False)
    output = result.stdout + result.stderr
    if len(output) > 65536:
        raise ValueError("preflight output exceeded its bound")
    print("PREFLIGHT " + " ".join(map(str, args)) + "\n" + output, flush=True)
    if result.returncode and not (allow_unsigned and "code object is not signed at all" in output):
        raise ValueError("preflight command failed")
    return output


def version_tuple(value):
    return tuple(map(int, value.split("."))) + (0,) * (3 - len(value.split(".")))


def inspect_executable(path, products, architecture, host_version):
    path = path.resolve(strict=True)
    if not path.is_relative_to(products):
        raise ValueError("archive executable escapes product directory")
    if architecture not in command(["/usr/bin/lipo", "-archs", str(path)]).split():
        raise ValueError("archive executable lacks runner architecture")
    loads = command(["/usr/bin/otool", "-arch", architecture, "-l", str(path)])
    minima = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|macos)\s+minos ([0-9.]+)", loads, re.IGNORECASE)
    minima += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", loads)
    if not minima or any(version_tuple(value) > host_version for value in minima):
        raise ValueError("archive executable deployment target is unavailable on runner")
    dependencies = command(["/usr/bin/otool", "-arch", architecture, "-L", str(path)])
    for dependency in re.findall(r"^\s+(/\S+) \(", dependencies, re.MULTILINE):
        if not dependency.startswith(("/System/Library/", "/usr/lib/")) and not Path(dependency).is_relative_to(products):
            raise ValueError("archive depends on an external build-machine path: " + dependency)
    # Inspect signatures; unsigned official archives may work with the test host.
    # Loading/launch failures remain failures: never re-sign or relax OS policy.
    command(["/usr/bin/codesign", "-dvv", "--entitlements", "-", str(path)], allow_unsigned=True)


def prepare_archive(directory):
    archive = directory / "webkit.zip"
    started = time.monotonic()
    with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as response, archive.open("xb") as destination:
        if response.headers.get("ETag", "").strip('"') != ARCHIVE_MD5:
            raise ValueError("official archive ETag changed")
        length = 0
        while chunk := response.read(1024 * 1024):
            length += len(chunk)
            if length > ARCHIVE_SIZE or time.monotonic() - started > 300:
                raise ValueError("archive download exceeded pinned size or time bound")
            destination.write(chunk)
    verify_download(archive)
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if len(entries) > 100000 or sum(item.file_size for item in entries) > 4 * 1024**3:
            raise ValueError("archive extraction exceeds diagnostic bound")
        if any(Path(item.filename).is_absolute() or ".." in Path(item.filename).parts for item in entries):
            raise ValueError("archive has an unsafe extraction path")
        product_directory = archive_product_directory(entries)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(directory)], check=True, timeout=120)
    products = (directory / product_directory).resolve(strict=True)
    if not products.is_relative_to(directory):
        raise ValueError("archive products escape extraction directory")
    architecture = platform.machine()
    host_version = version_tuple(platform.mac_ver()[0])
    webkit_version = None
    for name in ("JavaScriptCore", "WebCore", "WebKit"):
        framework = products / (name + ".framework")
        with (framework / "Resources/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        inspect_executable(framework / info["CFBundleExecutable"], products, architecture, host_version)
        if name == "WebKit":
            webkit_version = info["CFBundleVersion"]
    services = sorted((products / "WebKit.framework").rglob("*.xpc"))
    if not 1 <= len(services) <= 64:
        raise ValueError("missing or excessive WebKit XPC services")
    names = []
    for service in services:
        with (service / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        names.append(info["CFBundleExecutable"])
        inspect_executable(service / "Contents/MacOS" / info["CFBundleExecutable"], products, architecture, host_version)
    if not any("WebContent" in name for name in names) or not any("Networking" in name for name in names):
        raise ValueError("archive lacks WebContent or Networking service")
    if not isinstance(webkit_version, str) or not webkit_version:
        raise ValueError("archive has no WebKit bundle version")
    print(f"WEBKIT COMPARATOR revision={REVISION} commit={COMMIT} version={webkit_version} products={products}", flush=True)
    return products, webkit_version


def run_trial(name, cases, environment, directory, require_client=False):
    selector = "^(" + "|".join("VaneTests\\." + case.replace(" ", "/") for case in cases) + ")$"
    path = directory / (name + ".log")
    args = [sys.executable, str(ROOT / "scripts/run-native-tests.py"), "--skip-build", "--jobs", "1", "--filter", selector]
    with path.open("w") as log:
        child = subprocess.Popen(args, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            status = child.wait(timeout=240)
        except subprocess.TimeoutExpired:
            child.terminate()  # Native runner forwards TERM and performs manifest cleanup.
            try:
                child.wait(timeout=120)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            raise ValueError("native comparator timed out; cleanup is unverified; inspect retained host/manifest evidence: " + str(path)) from None
    if path.stat().st_size > 64 * 1024**2:
        raise ValueError("native comparator log exceeded diagnostic bound")
    output = path.read_text()
    print(output, end="", flush=True)
    verify_log(output, status, cases, require_client=require_client)


def main():
    if sys.platform != "darwin" or os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("official WebKit comparator is restricted to ephemeral macOS GitHub CI")
    # Resolve before DYLD setup; avoid /usr/bin/swift's protected launch wrapper.
    swift = subprocess.check_output(["/usr/bin/xcrun", "--find", "swift"], text=True, timeout=20).strip()
    directory = Path(tempfile.mkdtemp(prefix="vane-webkit-comparator-", dir=os.environ["RUNNER_TEMP"])).resolve()
    print("Comparator artifacts: " + str(directory), flush=True)
    products, version = prepare_archive(directory)
    environment = dict(os.environ)
    environment["PATH"] = str(Path(swift).parent) + ":" + environment["PATH"]
    # Match WebKit's run-webkit-app, including its auxiliary XPC processes.
    for key in ("DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "__XPC_DYLD_FRAMEWORK_PATH", "__XPC_DYLD_LIBRARY_PATH"):
        environment[key] = str(products) + (":" + environment[key] if environment.get(key) else "")
    environment.update(WEBKIT_UNSET_DYLD_FRAMEWORK_PATH="YES", VANE_WEBKIT_COMPARATOR_PRODUCTS=str(products),
                       VANE_WEBKIT_COMPARATOR_VERSION=version, VANE_WEBKIT_UA_REQUIRE_CLIENT="1",
                       VANE_WEBKIT_UA_POLICY_PROBE_ARM="control")
    run_trial("probe", [PROBE], environment, directory, require_client=True)
    for trial in range(1, 9):
        print(f"Official WebKit original-case cohort {trial}/8", flush=True)
        # The probe anchors the custom-scheme client fix. Separate markers attest
        # every earlier identity/continuation observation's own live services.
        run_trial(f"cohort-{trial}", CASES + [PROBE], environment, directory, require_client=True)
    print("PASS: attested official WebKit probe and eight cohorts (UA5/PW2); every live script observation and cleanup verified", flush=True)


def self_test():
    assert callable(globals().get("verify_log")), "Comparator must reject missing or failed test evidence"
    case = "ExtensionUserAgentTests testServiceWorkerIdentityFollowsSelectionWhenSharedPoolIsReused"
    fixture = "Vane fixture diagnostic: WEBKIT COMPARATOR FIXTURE SERVICES ATTESTED case=" + case.replace(" ", "/") + " scope=ua-identity\n"
    good = f"Test Case '-[VaneTests.{case}]' started.\n" + fixture * 2 + f"Test Case '-[VaneTests.{case}]' passed\nNative suite primary status=0; cleanup status=0\nVane fixture diagnostic: WEBKIT COMPARATOR ATTESTED\nVane fixture diagnostic: WEBKIT COMPARATOR SERVICES ATTESTED\nVane fixture diagnostic: WEBKIT COMPARATOR CLIENT ASSOCIATED\n"
    verify_log(good, 0, [case])
    for log, status in ((good, 1), (good.replace("passed", "failed"), 0),
                        (good.replace("cleanup status=0", "cleanup status=1"), 0),
                        (good + "*** Signal 4: Backtracing\n", 0),
                        (good + f"Test Case '-[VaneTests.{case}]' passed\n", 0),
                        (good.replace("WEBKIT COMPARATOR ATTESTED", ""), 0),
                        (good.replace("WEBKIT COMPARATOR SERVICES ATTESTED", ""), 0),
                        (good.replace("WEBKIT COMPARATOR CLIENT ASSOCIATED", ""), 0),
                        (good.replace(fixture, ""), 0),
                        (good.replace(fixture * 2, fixture), 0),
                        (good.replace(fixture, fixture.replace("scope=ua-identity", "scope=password-continuation")), 0),
                        (good.replace(fixture, "") + fixture * 2, 0)):
        try:
            verify_log(log, status, [case])
        except ValueError:
            continue
        raise AssertionError("Comparator accepted failed or incomplete evidence")
    password = CASES[-1]
    password_fixture = "Vane fixture diagnostic: WEBKIT COMPARATOR FIXTURE SERVICES ATTESTED case=" + password.replace(" ", "/") + " scope=password-continuation\n"
    password_good = good.replace(case, password).replace(fixture, password_fixture)
    verify_log(password_good, 0, [password])
    probe_evidence = "Vane fixture diagnostic: WEBKIT COMPARATOR ATTESTED\nVane fixture diagnostic: WEBKIT COMPARATOR SERVICES ATTESTED\nVane fixture diagnostic: WEBKIT COMPARATOR CLIENT ASSOCIATED\n"
    probe_good = f"Test Case '-[VaneTests.{PROBE}]' started.\n" + probe_evidence + f"Test Case '-[VaneTests.{PROBE}]' passed\nNative suite primary status=0; cleanup status=0\n"
    verify_log(probe_good, 0, [PROBE])
    for log, cases in ((password_good.replace(password_fixture, fixture), [password]),
                       (probe_good.replace(probe_evidence, "") + probe_evidence, [PROBE])):
        try:
            verify_log(log, 0, cases)
        except ValueError:
            continue
        raise AssertionError("Comparator accepted another fixture's provenance")
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "archive"
        path.write_bytes(b"official fixture")
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        verify_download(path, path.stat().st_size, digest)
        for size, checksum in ((1, digest), (path.stat().st_size, "0" * 32)):
            try:
                verify_download(path, size, checksum)
            except ValueError:
                continue
            raise AssertionError("Comparator accepted an altered archive")
    entry = zipfile.ZipInfo("Release/WebKit.framework/Versions/A/WebKit")
    assert archive_product_directory([entry]) == Path("Release")
    for entries in ([], [entry, zipfile.ZipInfo("Other/WebKit.framework/WebKit")]):
        try:
            archive_product_directory(entries)
        except ValueError:
            continue
        raise AssertionError("Comparator accepted missing or ambiguous framework roots")
    print("PASS: comparator rejects nonzero, fatal, missing-case, cleanup and attestation failures")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif sys.argv[1:]:
        raise SystemExit("usage: run-webkit-comparator.py [--self-test]")
    else:
        try:
            main()
        except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
            print("::error::WebKit comparator unavailable or failed: " + str(error), file=sys.stderr)
            raise SystemExit(1)
