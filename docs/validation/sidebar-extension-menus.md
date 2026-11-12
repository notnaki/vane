# Sidebar extension tab menus

Vane uses the public `WKWebExtensionContext.menuItems(for:)` API with the existing
profile-scoped `ExtTab` adapter. Page context menus continue to use WebKit's own
items. Sidebar menus expose only the items WebKit supplies for the tab context.

The subject is the clicked tab, including unselected tabs, favourites and individual
split panes. The split container uses its active pane; its Swap, Separate and Close
commands remain available. A bulk selection keeps its bulk commands, while extension
commands apply to the clicked row's tab. Folder, Space and placeholder rows do not
acquire extension commands.

Menu construction does not select the tab, call `performAction(for:)`, or synthesize
`userGesturePerformed(in:)`. A chosen extension command goes through the SDK's
native menu action, which owns the documented menu-click user gesture and permission
behavior. Vane does not grant permissions, host patterns or activeTab access itself.
Existing extension install/update consent, private access and runtime permission
policy still apply. Declared `menus` / `contextMenus` API permission is checked again
at dispatch; WebKit can otherwise retain usable native items after its revocation.

Each opening gets fresh SDK items. Hidden items and empty submenus are omitted;
disabled items, nested submenus, separators and check states are preserved. Before
dispatch, Vane checks the captured tab and store are still live, unlocked, in the
same profile/privacy boundary and exposed by the same adapter; the exact extension
context must still be installed, loaded and allowed in that tab. Changing selection
does not redirect the command. Closing or moving the tab out of its captured store,
parking the profile, disabling/replacing the extension or revoking private access
invalidates a retained action.

## Validation

`SidebarExtensionMenuTests` uses synthetic unpacked WebExtensions, a disposable
profile and extension options pages. Its product-menu checks materialize the real
SwiftUI tab menu with `NSHostingMenu` and dispatch native menu actions without
showing a window or injecting input. Coverage includes clicked-unselected tab
identity, selection changes, closed tabs, unloaded contexts, profile/private
boundaries, nested and disabled/hidden items, and refreshed empty menus.

Run the new focus-free suite with:

```sh
python3 scripts/run-native-tests.py --jobs 2 --filter SidebarExtensionMenuTests
./.build/debug/vane selfcheck --pure
```

Local evidence was collected on macOS 27.0.1 with Xcode 27.0. The macOS 26 runtime
and signed/notarized app presentation remain separate compatibility boundaries.

The focused related fixtures cover native tab-menu dispatch/disable, reorder and
window closure, sidebar highlight/selection, collapsed rows, adapter movement,
unsupported-capability disclosure and integrated-menu consent review. Checkbox
state/native toggle dispatch, both menu permission names, revoked API permission,
and mixed-section split bulk actions are also exercised by the new suite.

Focused local commands and outcomes are recorded with the PR. No personal browser
profile, real credential or user Keychain is needed. No Vane.app bundle is launched.
The CLI and XCTest hosts must exit, and the native wrapper verifies retirement of their exact disposable profile backends.

Required CI must run the full native suite and visible sidebar smoke checks: open
ordinary/favourite and split-pane menus by right-click and Control-click, invoke an
extension command, verify core commands, keyboard/VoiceOver menu access, and repeat
with a private window and a profile switch. Local focus-free dispatch does not prove
WindowServer presentation or foreground interaction behavior. Other tasks' apps
30238 and 29837 must remain untouched.

Local result on 2026-11-10: all 12 sidebar-menu fixtures and eight related fixtures
passed (20 tests total, zero failures). The native wrapper reported primary status
0 and cleanup status 0, with all 21 exact owned profile backends absent. The debug
`selfcheck --pure` run passed. Earlier red runs and all compile/test attempts are
retained in this checkout's ignored
`.superpowers/sdd/2026-11-10-remaining-limitations/` directory. Visible smoke and the
full required CI suite remain outstanding until run by the parent/CI owner.
