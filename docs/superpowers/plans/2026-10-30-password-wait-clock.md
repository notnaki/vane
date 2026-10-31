# Password fixture wait clock qualification

The actual private `PasswordAutofillTests.wait` used wall time for its five-second
deadline and checked expiry only after a false predicate. A wall jump could make
it fail early or run too long, and a true result arriving after expiry could pass.
These are demonstrated helper defects. They do not establish that a wall jump,
an executor stall or any particular mechanism caused the historical b029274
continuation navigation failure or the old 8.23-second diagnostic commit delay.

The helper now uses one `ContinuousClock` five-second deadline and checks
cancellation and expiry before and after awaiting the actual predicate. Wall
time is retained only as failure diagnostic metadata, alongside monotonic elapsed
time. Existing failure provenance, diagnostic callbacks and security assertions
are unchanged. The helper cannot preempt an indefinitely blocked predicate.

## Controlled evidence

Base: ACK repair `d4fc2e4e61a9f6f69c9969889553603e218055a9`, local macOS 27 /
Swift 6.4 native SwiftPM backend. The private per-test wall reader defaults to
`Date.now`; controls offset that reader without changing any system clock.
All controls call the actual helper, rather than a copied wait algorithm.

The predeclared initial RED matrix produced three expected assertion failures,
zero unexpected, primary 1 / cleanup 0:

- A forward 60-second wall step caused premature timeout while a genuine SDK
  username message was held for 400 ms before native processing.
- A backward 60-second step with a false predicate failed to expire; the
  independent monotonic seven-second supervisor cancelled and joined the
  cooperative wait and marked the control failed.
- A bounded async predicate returned true after six seconds and the old helper
  incorrectly accepted it. The repair rejects that late result after return;
  it does not claim to interrupt the predicate at five seconds.

The first GREEN matrix (three tests) and class run (55 tests) passed 0 / 0,
but independent review identified a fault-admission gap in the forward control:
it did not assert that the wall step happened while native processing was still
pending. Those runs are preserved observations, not final qualification.

After both runs' exact hosts exited, the control was strengthened to step once
only with a matching received, unprocessed, undiscarded and nonduplicate receipt,
and to assert the pending-step marker. The actual old Date helper was restored
in place for one updated forward RED: one intended assertion failure, zero
unexpected, pending marker true, primary 1 / cleanup 0. The identical monotonic
helper was then restored for the final predeclared qualification:

1. Three corrected controls passed, no failures or skips, primary 0 / cleanup 0.
   The forward control asserted a genuine pending step. The backward control
   timed out at five elapsed seconds; the late true was rejected after six.
2. The complete `PasswordAutofillTests` class passed 55 tests with no failures or
   skips, primary 0 / cleanup 0, on the same frozen source and XCTest binary.

All twelve exact native host launches across the six runs were independently
rechecked absent, and each run's owned backend retirement completed. Full raw
logs, exact sources/diffs, copied binaries/hashes, retirement manifests, the
finite plans and final aggregate are under
`/Users/nuh/.codex/artifacts/vane-extension-repair-2026-10-28/password-wait-clock/`.
Independent source review cleared test blob
`a1f59d94eb7e6712638b73de992e923a66579f3b` after the admission correction.

This changes only the test fixture. The ACK repair remains a separate commit;
known inline username-submit delays remain for the next scoped repair. Latest
main must still be integrated and qualified, and the historical continuation
failure remains unresolved. No full CI, push or merge is authorized by this note.
