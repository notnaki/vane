# Remaining actionable browser limitations

The user asked to implement five previously proposed improvements, without questions: optional local filter-file refresh, broader safe EasyList coverage, improved password autofill for open shadow DOM and multi-step forms, extension actions in sidebar tab menus, and cookie/session migration beyond Arc. Sync and passkeys remain excluded.

Use Vane's existing native Swift/AppKit/SwiftUI/WebKit architecture. Keep each domain independently reviewable. Existing snapshot imports stay snapshots; linking an original file is explicit opt-in and keeps a last-good owned snapshot across source loss or invalid updates. Recompile the complete candidate before publishing changes. Preserve current bounds, private isolation, security-scoped access and safe restore behavior.

Additional EasyList support must preserve rule meaning within public WebKit capabilities. Prefer useful accurately representable syntax over approximate support; report unsupported constructs. Real WebKit tests must establish the newly accepted rule behavior.

Autofill should discover and operate on visible controls in open shadow roots, including dynamically installed controls. Preserve exact HTTPS-origin, document/field-token, focus, ambiguity and private-mode restrictions. Improve unusual multi-step flows only where available signals establish the intended username/password relationship; never auto-submit or broaden cross-origin filling.

Extension menu items should appear for the tab the sidebar row represents, using public WebKit extension APIs and existing host permission/lifecycle policy. Invocation must target the clicked tab even if another tab is selected. Private/profile isolation, tab closure, unloaded extension contexts and sidebar rows without real tabs must be respected. Unsupported extension APIs remain unsupported.

General browser import should offer explicit optional cookie/session migration for supported Chromium profiles beyond Arc, reusing and separating the tested Arc decryption/cookie primitives where useful. Read source snapshots only, use browser-specific Safe Storage identities, avoid logging or temporary plaintext credentials, retain full cookie attributes, reject unsupported/expired/partitioned records, preserve existing destination cookies, and report imported/skipped/failed results truthfully. No real user profile or Keychain access is needed for automated validation; use injected synthetic secrets and isolated stores. Broader Firefox/Safari session extraction is not required without a supported decryption path.

Account/provider, device, macOS-version and notarized-release compatibility claims still require their corresponding evidence. Do not activate/order-front windows, inject input, or capture screens without coordinating foreground ownership; other active tasks own preview apps 30238 and 29837. Never touch those apps. Focus-free fixtures and compilation may run concurrently.

The parent owns final independent reviews, integration, strict current-main CI, squash merges and cleanup. Each implementation may stop at a validated PR for parent review and merge.
