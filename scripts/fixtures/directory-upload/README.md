# Standalone WKWebView directory-form reproduction

This probe uses only AppKit and public WebKit APIs. It imports no Vane code and
adds no scripts, file grants, security preferences or entitlements beyond the
repository's production `Vane.entitlements`. It is a diagnostic fixture, not an
upload workaround. Requires a logged-in macOS desktop and Xcode/Swift 6.

1. Start a loopback receiver in a terminal using a **new disposable directory**:
   `python3 scripts/fixtures/directory-upload/server.py /tmp/directory-probe-evidence`.
   It prints a port and writes synthetic text/binary files in `tree/` and `files/`.
2. Run `python3 scripts/fixtures/directory-upload/build-probe.py`. This compiles
   and signs a uniquely identified app and prints its executable path.
3. Run that executable with the receiver's printed URL, for example:
   `"/tmp/vane-directory-probe-EXAMPLE/DirectoryProbe.app/Contents/MacOS/probe" http://127.0.0.1:PORT/directory`.
   Keep its stdout as a policy/picker/termination trace. Record its PID, start
   time and bundle path if running multiple task-owned copies.
4. Click Choose Files, use ⌘⇧G to choose the printed `tree/` folder, and Open.
   The page and `events.json` must show `tree/top.txt` with hex
   `666f6c64657220746f70206c6576656c0a` and `tree/nested/child.bin` with
   `00ff01800d0a`. This records selection and readable bytes, **not an upload**.
5. Click Send form. A successful directory submission must reach
   `/receive/directory` with exactly those relative filenames and bytes. The
   receiver saves raw `multipart.bin` and validates every part; a mismatch gets
   HTTP 422. On macOS 27.0.1 the content process terminates before the POST policy
   delegate is called, no form POST arrives, and macOS records a `WEBKIT`
   `EXC_GUARD` report for `probe` with `decidePolicyForNavigationAction` on its stack.
6. Close the probe window (the process exits), launch the executable with `/files`,
   select both ordinary fixtures from `files/`, and submit. The receiver verifies
   exactly `top.txt` (17 bytes) and `child.bin` (6 bytes), with no directory paths.
   `events.json` distinguishes readable selections from verified POST receipt.
7. Close every probe window and verify its tracked PID has exited. Stop the
   receiver with Ctrl-C and remove only the disposable evidence/build directories
   when no longer needed. Leave other Vane apps and servers running.

Vane's production picker now cancels directory controls on macOS 27.0 with an
explanation, so use this standalone client or the opt-in raw selected-URL XCTest
below to retest the engine. The raw fixture delegate intentionally bypasses Vane's
picker safeguard; its skipped normal-suite test is never a compatibility pass:

```sh
VANE_RUN_KNOWN_COMPAT_FAILURES=1 swift test --filter UploadSubmissionTests/testDirectoryFormSubmissionKnownWebKitFailure
```

The receiver binds only to `127.0.0.1`. These tiny fixtures do not cover large or
interrupted uploads, authenticated services, or every WebKit/OS version.
