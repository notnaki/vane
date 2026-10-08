# Download reliability on macOS 27

Vane uses `WKDownload` for transfers, cancellation, progress, redirects and resume
requests. Resume data remains opaque: Vane persists WebKit's bytes rather than
constructing Range requests or stitching fragments itself. Regular profiles have
separate records and resume directories; the Library intentionally combines
regular profiles. Private records and resume data stay in memory.

## Audit evidence

The audit uses deterministic loopback HTTP responses and temporary destinations,
not public downloads or the user's files. Initial runs on macOS 27.0.1 (26A434)
reproduced these defects:

- A second Resume request produced an oversized file (507,904 bytes instead of
  the fixture's 262,144).
- Pause followed immediately by Cancel revived a cancelled row when its pause
  callback arrived.
- Removing a live row did not stop the transfer or clean its partial destination.
- Cancelling an already completed row deleted its finished file.
- A damaged binary plist with a valid header passed resume validation.
- A directory at the saved destination was restored as a completed file.
- Unknown-length transfers did not publish received bytes until completion,
  leaving live progress and partial-file ownership untracked.
- HTTP 416 in response to Range produced a zero-byte file and WebKit delivered
  a completion callback. Vane accepted that as completed.

Review regressions also exposed a filename reservation race (eight concurrent
downloads chose only six paths), premature pause/quit handling, lost private retry
cookies, and unsafe deletion of replacement files. Those cases now have focused
coverage. Final validation is recorded below.

The focused suite comprises 32 real WebKit cases, eight filesystem cases, and 12
existing Library/hover cases. It checks exact bytes, persisted rows, per-profile
ownership, resume-blob cleanup, inode-safe partial cleanup, redirects, range refusal,
changed validators/length, gzip/unknown length, destination loss/write denial,
resume-storage failures and repeated/cancelled/pending actions.

Local validation: all 52 focused tests and `selfcheck --pure` pass on macOS
27.0.1 (26A434). The signed restart driver passes both running-transfer quit and pending-manual-pause
quit, with exact final SHA-256, persisted state and Range requests. Full XCTest and
standard browser smoke remain queued outside the smoothness chat's native window.

## Reproduce

```sh
swift test -j 4 --filter 'DownloadReliabilityTests|DownloadWebKitTests|DownloadLibraryTests|DownloadsHoverTests'
./.build/debug/vane selfcheck --pure
python3 scripts/check-download-reliability.py
python3 scripts/check-browser-smoke.py
```

The restart script assembles a temporary signed sandbox app, launches it with an
isolated directory beneath Downloads, quits a live transfer through AppKit, then
relaunches the same bundle and resumes. It checks the final SHA-256, destination,
JSON state and resume-blob cleanup. It logs owned PIDs/start times and waits for
exit, unregisters its WebKit store, stops its loopback server and removes fixtures.

Headless XCTest fixtures cover real WebKit transfers and byte comparisons; the
signed script supplies process-restart and sandbox evidence. Builds and native
checks are scheduled outside the smoothness chat's reserved profiling windows.

## Behavior and limits

Only a readable regular final file of the expected size, where WebKit supplies a
reliable size, can become completed. Subsequent document edits remain usable in
history. The production app does not know arbitrary servers' hashes; fixture tests
compare every byte or a known SHA-256.

Resume can still fail when WebKit's partial-response state, server validators,
authentication, or destination access is unavailable. Fresh Retry makes a new
request and selects a fresh destination using the current folder preference; a
file-specific Save-panel choice needs a new panel. Retry requires a recorded GET;
legacy rows with unknown methods, POST exports and blob/data URLs retain Copy Link
and need the originating page to generate another download. Private fresh retry
uses the original live page so its session cookies are preserved; once that page
closes, Vane does not substitute another private session.

Folder permission fixtures use real filesystem denial/missing paths and isolated
bookmark lifecycle checks. They do not forcibly revoke the user's macOS privacy
settings. Physical disk exhaustion, unplugging a volume, power loss and arbitrary
server correctness are not guaranteed by loopback fixtures. Unverified or replaced
files must be preserved rather than deleted as purported partial downloads.
In particular, macOS WKDownload has no public destination-created callback. An
immediate cancellation before the first written-byte notification can retain an
empty file: Vane cannot safely distinguish it from a foreign file created at the
chosen path. Cleanup never polls and adopts such files. WebKit's destination policy
requires an absent file and remains responsible for exclusive creation; Vane's
reservations also prevent concurrent automatic downloads choosing the same path.

Resume blobs saved by this version carry a SHA-256 checksum. Legacy opaque blobs
can only be checked for property-list structure before WebKit interprets them;
syntactically valid legacy data is not proof of resumability. Server responses
without a usable length cannot be independently checked for truncation without
a server-provided digest; WebKit still determines transfer success.

Known missing/unwritable destinations are rejected before handing the path to
WebKit, with an explicit failed row. A macOS 26 CI run exposed delayed native
failure delivery for a readonly folder; destination preflight removes that stall.
