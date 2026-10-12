# Complete extension management

## Intent and constraints

Make installing, understanding, using, updating, and troubleshooting local MV2/MV3 extensions a complete native browser feature. Extend the existing WebKit host. Preserve installed extension UUIDs, origins, controller identifiers, required approvals, disabled state, pins, and storage. macOS 26 remains the minimum. No Vane service or account. Private profiles cannot install extensions. The user explicitly instructed continuous implementation through validation, independent PR review, fixes, and squash-merge without further design gates.

## Manager

One retained, resizable window per profile, opened from Extensions, Advanced Settings, and the command palette. The visible profile remains fixed to that window. Native searchable list/detail layout, counted All/Enabled/Disabled/Needs Attention filters, metadata and icons retained for inactive installations, common enable/pin controls, progress and actionable errors. At narrow widths use list/detail navigation with a Back control. Include first-install, private-profile, and no-results states. Detail actions: options, update by choosing a source folder, retry, reveal source, remove with confirmation, copy sanitized diagnostics, and supported grant revocation. Native keyboard list selection, focus, accessibility labels, dynamic system colors/fonts, short Look motion, vaneMotionPolicy.

## Accepted code and updates

Keep external source paths as legacy installation keys, and preserve assigned context identifiers. Add a versioned profile-scoped record of accepted managed revisions and display/access metadata. Import through private staging, copying regular files only, rejecting symlinks and special files, enforcing file-count/per-file/total limits, and validating manifest and referenced resources before review. Review always precedes context activation. The staged resources cannot be edited through source-folder changes during consent. Commit a revision only after activation/background validation and metadata persistence succeed. On a failed or declined candidate retain the accepted revision and its old approval; if replacement activation fails, reload the prior code with its old grants. A rollback restores code, not extension-owned data mutations. Disabled updates remain disabled. Migration snapshots validated legacy folders, keeping their identity and approval; unavailable legacy installations remain recoverable and removable. Existing folder changes before migration receive the existing added-access gate; after migration edits apply only through explicit updates. New folder selection can repair a missing source without creating a new installation. Removal deletes only Vane-owned revisions and installation metadata, never source code; reinstall gets a new identity.

## Permissions and diagnostics

Display required installation access, optional declared access, and current temporary/runtime grants separately. Show finite expiration and explain context-session lifetime. Revocation resets only supported optional/runtime grants and denials, preserves required approval, and cannot undo past website changes. Required access can be stopped through disable/remove. Observe grant/error changes for accurate display. Copied diagnostics use allowlisted extension/version/platform/state/API/error-code fields; omit paths, actual website targets, content, storage, arbitrary error strings, credentials, and tokens.

## Runtime

Use public WebKit commands with existing browser shortcuts taking precedence; scope dispatch to a normal profile browser window and avoid modal/text-entry interception. List available commands and collisions. Audit native WebKit webpage menus before adding host menu items; preserve the existing link-menu reconstruction. Stop advertising page menus as unsupported only when real context-menu behavior is verified. Improve tab/window diff notifications for moves, selection, focus and closing while preserving stable adapters and locked/profile/private isolation. Keep popups/options associated with live contexts and close them on disable/removal. Native messaging remains unavailable pending separate host discovery/allowlisting, consent, framing/limits, signing/sandbox, process and port lifecycle design.

## ZIP decision

Investigate public WebKit ZIP loading and available bounded extraction. ZIP import is optional; ship only with pre-write traversal, absolute path, duplicate/case conflict, symlink/special-file, entry-count, expanded-size and corrupt-manifest coverage. Otherwise document folder extraction in Finder and retain folder drop as the convenience path.

## Evidence and delivery

Focused extension XCTest regressions exercise code update failure, consent cancellation, identity/storage retention, source loss, migration, profile isolation, disabled state, removal, temporary grants and lifecycle. Build the assembled app and verify manager sizes, search/filters/actions/drop, keyboard navigation, popup/options and representative third-party content-script/blocker/password-manager workflows where feasible. Record exact versions, provenance, results, unsupported APIs and unverified behavior. Do not use real credentials. Track task-owned app bundle/PID/start time and terminate only those instances after successful merge. Update INTEGRATIONS, privacy/backup exclusions as applicable, then PR, independent current-head review, CI, squash-merge and verify.
