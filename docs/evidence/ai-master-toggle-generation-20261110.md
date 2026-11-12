# Max master-switch admission race

Base: approved AI feature head `637dea23e175b0bf41961f44cab0bb3b56d3d89b`.
Repair worktree: `/private/tmp/vane-ai-master-toggle-generation-20261110`.
The original worktree and PR #633 remain unchanged. No pushes, branch updates,
workflow dispatches, app launches, desktop actions, or live accounts were used.

## Verified failure

`MaxPane` originally passes its `@AppStorage("appleAI")` projection straight to
the master Toggle. This writes the preference without advancing BrowserAI's
revision or cancelling pending requests. A suspended credential request can
therefore resume after off→on with both `enabled == true` and its captured
revision still current.

The real BrowserAI dispatcher was exercised with a gate at the credential I/O
boundary, routing summaries to ChatGPT. The original UI seam was reproduced
with an actual `AppStorage` projection, without calling `settingsChanged()`:

```swift
@AppStorage("appleAI", store: UserDefaults.vane) var masterEnabled = true
$masterEnabled.wrappedValue = false
$masterEnabled.wrappedValue = true
```

Both writes run on the main actor without an intervening suspension. Releasing
the credential gate produced:

```text
EVIDENCE master off/on: entered=true enabled=true revision=3->3 uploads=1 results=1
FAIL master off/on during refresh prevents stale page-text upload
```

Retained log: `/tmp/vane-ai-toggle-red-appstorage.log`. A behavior-preserving
extraction of that preference binding into the production seam also failed
before adding invalidation (`/tmp/vane-ai-toggle-red-production-binding.log`).

## Small repair and regression

The master Toggle now uses `BrowserAI.enabledBinding`. Its explicit setter
synchronously persists each changed value and calls the existing
`settingsChanged()` cancellation/revision path. Same-value writes are ignored.
An asynchronous `onChange` observer is intentionally avoided because SwiftUI
can coalesce off→on before the observer runs. No transport, OAuth, account,
feature-route, credential, or motion behavior is otherwise changed. The prior
Swift 6.3 endpoint-setter closure workaround remains untouched.

The committed routing harness uses this exact production Binding, also used by
MaxPane, with no manual invalidation in the master-switch cases. It verifies
zero stale uploads/results, synchronous revision changes on both edges,
cancellation of the suspended request, fresh work after re-enabling, harmless
same-value writes, private-mode blocking, and stale local-result rejection.

```text
EVIDENCE master off/on: entered=true enabled=true revision=3->5 uploads=0 results=0
```

## Focused validation

- All eight routing checks pass (`/tmp/vane-ai-toggle-green-final.log`).
- Removing master invalidation restores the stale upload; removing request
  cancellation fails its assertion; removing the same-value guard cancels fresh
  work and fails its assertion. Logs: `/tmp/vane-ai-toggle-mutation-*.log`.
- The other four offline AI harnesses pass: cloud transport, connection
  migration/isolation, OAuth/JWT/SSE, and session refresh/sign-out.
- The exact production MaxPane/Pane source and changed BrowserAI typecheck
  against the previously compiled feature module; no test host or UI is run
  (`/tmp/vane-ai-toggle-max-pane-typecheck.log`). Isolating the entire settings
  file instead shadows the compiled Prefs type and loses its other-file
  extensions; that attempt is not counted as a passing build.
- `git diff --check` passes. No full suite or CI was dispatched under the
  integration serialization gate. Hosted Swift 6.3.3 validation still belongs
  to the later AI integration slot.
