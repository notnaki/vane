# Saved workspaces and Space templates

The user wants a named, reusable setup that can be reviewed and recreated as a new Space on macOS 27. Preserve nested folders, sidebar order, pinned rows, custom names and supported split arrangements. Templates belong to their source profile. Save, rename, update, delete and creation must leave existing committed data intact on failure.

## Architecture

Use a versioned `space-templates{ProfileManager.suffix(profileID)}.json` beside the existing profile files, written through SnapshotPersistence. Each template has an ID, name, profile ID, modification date, Space appearance and an address-only SpaceLayout. Use an optional `layout` on Space to commit all recreated contents in a single atomic spaces.json write. Legacy Space fields remain compatible. A layout is used only while its row addresses agree with the legacy lists; subsequent live saves refresh it. This avoids multi-file creation transactions and lets backup/restore include ordinary JSON without a separate backup implementation.

SpaceLayout stores stable tab identities, addresses, pinned homes, display titles, optional custom names, both Pins shapes and splits. Recreating remaps every tab and folder ID, including parent and pane references. Favourites stay profile-wide and are not captured. Blank/file/internal pages are omitted from templates. Live folders become ordinary snapshot folders. Unsupported split panes are omitted; surviving groups of two to four preserve order, direction, focus and normalized divider weights.

## Privacy and authentication

Templates have no WebKit interactionState, cookies, credentials, website storage, history, Keychain values or live-source configuration. Web addresses remove userinfo and credential-like query parameters and fragment parameters. Ordinary query/fragment navigation remains. Existing profile cookies may be used when a recreated page loads; no signed-in session is copied. Local Easel/file documents are excluded with a visible count.

Capture authenticates all protected source folders using Vane's FolderAuthentication grants and the system authenticator, including nested locks. No protected titles or addresses enter the save preview before authentication. Templates retain lock flags with fresh folder IDs. Their library previews hide protected rows; showing or recreating protected contents requires authentication against the template's profile and folder IDs. Check grants again at commit so a Mac lock invalidates an open preview.

## Interaction

Expose Save Space as Template and Space Templates from the current Space menu, and New Space from Template from the creation menu. A native sheet lists the current profile's templates, previews Pinned/Today folders and tabs, indicates split direction/weights and omitted pages, and provides named save/create, rename, update from current Space and confirmed deletion. Failed writes retain the form and selection with a retryable error. Updating recaptures the source; it does not change already created Spaces.

Animate list/preview selection with Motion.list and Look.quick, respecting Reduce Motion and Battery Saver. Disable private and Little Vane entry points. Profile changes dismiss the sheet; operations revalidate ownership and authentication before writing.

## Validation

Focused XCTest tests cover sanitization, duplicate addresses, identity remapping, nested locks, cross-profile refusal, corrupt/future files, rename/update/delete failure recovery and atomic creation. Browser regression coverage checks initial load, Space switching, disk rebuild, session restore and custom name persistence without WebKit state capture. Build and run pure checks, then perform a macOS 27 sheet smoke check with a tracked isolated test app. Obtain independent review of the latest PR diff, fix findings, wait for required CI, squash-merge and clean up tracked processes.
