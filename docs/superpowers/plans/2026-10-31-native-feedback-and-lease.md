# Native feedback and lease-fixture qualification

## Original required-CI failures

PR #560 head `ce86e597` integrated with main `641bc399` in required run `41213364787`. Source/build/packaging, native shards1/2 and strict worker-UA classification passed. Shard3 failed `FeedbackOcclusionTests.testMovingPreviewRevokesHoverAndDismissalDoesNotAdmitAStationaryRow`: hover remained true after an offset mutation and one queue drain. Shard4 failed `ExtensionCodeStoreTests.testLeaseHolderBootstrapDelayDoesNotConsumeAcquisitionBudget`: the child was alive at the original ten-second bootstrap deadline, with no milestone file or stderr, then was reaped.

The original shard3/4 ZIPs were downloaded and SHA256 verified (`288a5900bd16ccf4a8980c5deb08e52c8ff371dbd29320031fd635289bfe2fb7`, `68c34e3dfdac59b3c84a6b11bb5753856cc1b5bcffac07e9713523fe919fb526`). Logs/manifests remain preserved. No unchanged CI retry establishes a repair.

The hover fixture did not acknowledge committed cover geometry. Independently, the marker observed only its own geometry: moving an ancestor could change window-space coverage without invalidation. The lease child's first milestone followed Python initialization, an intentional four-second sleep and marker opening. Its absent milestone cannot identify which of those historical operations stalled; production lock acquisition is not implicated by that record.

## Controlled RED

A real native ancestor-only movement established visible owner, initial hover, unchanged marker-local frame and actual pointer coverage, then failed only the expected hover-revocation assertion. A child-only invalid `PYTHONHOME` established the external-runtime dependency: the old Python child failed before lease acquisition and the control reported one intended assertion. Two native cases, two intended assertions, zero unexpected; primary1/cleanup0 and both owned hosts exited. This does not assert that PYTHONHOME caused the original child4114 failure.

Two archive controls failed as expected because the old packer omitted the new native helper and accepted a missing helper. All RED source/log evidence is retained under `closeout/ci-41213364787/` in the task artifact root.

## Repairs

- Observe scoped ancestor frame/bounds and owning-window changes through weak marker-owned notifications. Reparent/update refresh and dismantling clean observation tokens. Input hit testing and stationary-pointer admission remain unchanged; geometry only revokes feedback.
- Own the AppKit loop and admit the exact visible host, anchors and native preview coverage. Geometry admission is read-only, uses the existing ten-second bound, and never waits for hover. Original immediate hover assertions, queue drain, click cadence and stationary-pointer sequence remain.
- Replace the Python-backed lease owner with `NativeLeaseHolder`, a test-only minimal C executable using real `flock`, `poll/read`, atomic `rename`, and monotonic timing. Resolve its fixed sibling path beside the actual XCTest bundle. Record entry before intentional delay. Preserve parent bootstrap10s, acquisition3s and child command5s. No runtime compiler, PATH lookup, Python fallback, forked AppKit host, or app-bundle copy.
- Require and preserve the helper executable in shared CI runtime packing/restoration; missing or nonexecutable payloads fail closed.

## Qualification and retained failed attempt

The two exact native RED controls passed after the repairs. All eight artifact fixtures passed, including helper roundtrip/modes and missing/nonexecutable rejection.

The first broader preflight exposed a fixture-lifetime error introduced during this repair: leaving loop close in a post-method XCTest teardown block deadlocked the invocation. An actual `/usr/bin/sample` captured the owned nested `NSApp.run` inside XCTest's method waiter. The exact recorded host39566/start1793460923453456 was revalidated against its executable and kernel start before termination; primary1/cleanup0, both owned hosts exited. That failed attempt is preserved, and its remaining planned repetitions did not run.

The corrected `withMountedFixture` cleans window/store state and joins the loop inside the test body before XCTest must finish it. Both throwing and successful paths retain cleanup and restore prior policy after join. Three newly predeclared fresh affected cohorts then passed 30 cases each, zero skips/failures/unexpected, primary0/cleanup0, and all six exact primary/cleanup hosts exited. Swift/test binary fingerprints and supplemental C/helper/configuration hashes stayed frozen. An outer90s process bound guards another deadlock without changing any native outcome deadline.

Independent review of the final seven-file implementation and fixture lifetime found no unresolved actionable findings. Full required CI on the new reviewed head remains necessary. The historical `b029274` failure is still not declared repaired; its original test stays blocking. The exact worker-UA platform limitation is unchanged and remains the sole accepted advisory classification.
