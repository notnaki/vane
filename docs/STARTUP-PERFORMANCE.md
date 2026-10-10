# Startup and session restoration measurements

The October 2026 investigation measured session input preparation, parked tab
construction, native presentation, WebView creation, and first-page readiness
separately. Two repeated operations were responsible for a substantial part of
large-session restoration: decoding the same document repeatedly, and using
interactive tab insertion to rebuild folder shapes for each restored row.

## Reproducing the measurements

Build before reserving a profiling window. The XCTest measurements are opt-in;
routine CI skips them and has no wall-clock thresholds:

```sh
swift test -c release -Xswiftc -enable-testing --filter SessionSnapshotTests
VANE_STARTUP_PERFORMANCE=1 xcrun xctest \
  -XCTest VaneTests.StartupRestorationPerformanceTests \
  .build/out/Products/Release/VaneTests.xctest
python3 scripts/profile-startup.py \
  --binary .build/out/Products/Release/vane \
  --evidence /tmp/vane-startup-measurements
```

Use the product path emitted by SwiftPM on the installed Xcode version; older
versions use `.build/release`. The native launcher assembles and signs a unique
test bundle, creates a synthetic data directory, records every app PID, launch
time, bundle and data path, and verifies each owned process exits. It retains
the evidence and synthetic data for inspection. It never points at normal Vane
data. Do not launch it during another agent's profiling window.

For a baseline checkout at `f24aa5f`, copy the performance test and launcher into
that checkout. Compile the tests with `-Xswiftc -DVANE_STARTUP_LEGACY_PIPELINE`.
That branch of the fixture reproduces the original restore-input pipeline.
The baseline executable must remain built from the baseline production sources.

The phase fixture uses 10, 100, 500 and 1,000 tabs, three repetitions per size,
and a 4 KiB opaque saved-state payload per row. Every background row must stay
parked with no WebView. The native fixture uses the same sizes, all Today rows,
selects the last row, and serves a loopback page. It checks that only the selected
page was requested. Native readiness is the page's beacon after two animation
frames; it includes process startup and window presentation. The separate XCTest
page fixture measures WebKit title/load readiness and sleeping-tab resume, not
rendered-frame readiness. Its metadata completion mark means all restored rows
are installed; background pages intentionally remain parked.

## Baseline attribution

On macOS 27.0.1, Xcode 27, arm64 MacBookPro18,4, optimized testable builds, the median
phase timings in milliseconds were:

| Tabs | Cached disk read | One decode | Restore input | Parked construction | New blank tab |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 0.045 | 0.193 | 1.612 | 1.620 | 0.038 |
| 100 | 0.119 | 1.365 | 13.700 | 20.063 | 0.175 |
| 500 | 0.451 | 6.820 | 66.386 | 368.682 | 0.752 |
| 1,000 | 0.894 | 14.238 | 133.037 | 1,138.488 | 1.575 |

A healthy restore did three session reads and nine full JSON parses, including
validation, recovery detection, migration URLs, splits, Spaces, selection and
the version probe. One validated snapshot now supplies all those fields. A
damaged primary still tries the previous generation and preserves the recovery
flag; no restored metadata is discarded.

A separate sampling run (excluded from timings) attributed 455 of 912 main-thread
TabStore-initialization samples to the interactive insertion/motion path, with
shape rebuilding prominent. Pin-name backfill also accounted for 245 samples.
Restoration now constructs rows locally using the existing section insertion
rule, then publishes and adopts folder shapes once. Normal interactive tab
creation and its motion policy are unchanged.

## Coverage and limits

Regression coverage checks one read per healthy generation, fallback recovery,
legacy schemas, empty windows, mixed section order, duplicate URLs, selected
identity, titles, custom names, home URLs and parked state. Existing real-WebKit
session fixtures check distinct navigation histories for duplicate URLs and
private exclusion. Draft protection, shared presentation, crash recovery and
locked-folder fixtures are included in focused validation.

The opaque phase payload measures decode/copy costs; it is not a substitute for
real WebKit interaction-state compatibility tests. Native fixtures have no
interaction-state blobs. Relaunches distinguish first-process and repeated warm
runs, without purging OS caches. Native measurements use a minimal signed fixture
bundle with the executable and resources, without the distribution's helper XPC
services. Other agents' compilers and measured workloads
are serialized through a shared profiling lock; normal user/OS activity remains.
Full-window presentation, WebKit process startup, normal background services,
and pin-name backfill still contribute to total startup. No persistence format,
profile boundary, sidebar styling, draft policy, Reduce Motion or Battery Saver
behavior was changed.
