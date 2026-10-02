# Populated Space swipe performance

Goal: remove saved-state decoding, folder reconstruction and repeated stash validation from swipe frames while preserving titles, folders, duplicate tabs and fresh state between gestures.

Evidence: rendering the existing preview 120 times against 120 saved pages with 16 KiB interaction state each took 419 ms. Regression tests demonstrate that a single preview rereads both its folder shape and saved titles during rendering. Baseline: 88 tests pass.

Implementation: capture the preview's saved metadata, folder rows and Today count in its initializer. Retain one preview per encountered neighbour in SpaceGesture and release the cache when the gesture ends or aborts. Use stable preview identity to skip unchanged SwiftUI subtree updates while its parent offset moves. Keep switch-time disk revalidation and persistence unchanged.

Validation: failing then passing snapshot tests; verify cache reuse and refresh after interruption; compare the same 120-frame fixture; run swift test, release selfcheck --pure, bundle build and isolated sandbox browser smoke. Review current PR diff independently, address findings, require CI success, squash merge. Quit and verify exit of all task-owned fixtures.
