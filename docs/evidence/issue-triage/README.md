# Issue triage captures

Captured from the native `IssueReportWindowTests.testReportWindowRendersAtMinimumSizeWithLogs`
fixture on macOS 27.0.1 with Xcode 27. Logs are enabled for the screenshot; new drafts
start with them disabled.

- `report-light.png`: 680 × 760 content window, light appearance.
- `report-dark.png`: 580 × 560 minimum content window, dark appearance. The form
  scrolls so its preview remains reachable while sharing actions stay visible.

The fixture uses synthetic reproduction text and isolated WebKit stores. Its
environment metadata comes from the XCTest host; packaged Vane uses its own
version and build. This is a new window: previously the command-bar report row
opened a blank GitHub issue directly.

Regenerate with an existing output directory:

```sh
VANE_TRIAGE_CAPTURE_DIR=/tmp/vane-triage-captures \
  python3 scripts/run-native-tests.py --jobs 1 --filter IssueReportWindowTests
```
