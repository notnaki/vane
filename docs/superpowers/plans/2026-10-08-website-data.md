# Website data implementation plan

Goal: Make stored website data visible and removable within a captured Vane profile on macOS 27, with honest categories, effects, asynchronous state and isolation.

Design: Use supported `WKWebsiteDataStore` fetch/remove APIs. Keep the actual records with the store that supplied them. WebKit groups records by registrable domain; display those names rather than inventing origin-level precision. The public SDK exposes no record size; show usage unavailable. Private site controls use only the selected tab's ephemeral store. Website-data removal preserves Vane's site settings, history, bookmarks and saved passwords.

1. Add `WebsiteData.swift` with a store-bound backend and a main-actor observable controller. Fetch all public types, group entries, filter search, select available categories, remove selected records, and fetch again before reporting success. A slow removal remains pending; never treat a timeout as cancellation. Ignore stale callbacks and refuse deleted-profile operations.
2. Add `WebsiteDataSheet.swift` using Vane's settings typography and motion policy. Include loading, empty, search, category selection, confirmation, open-tab effects, unavailable usage, progress, retry and retained-data states. Connect Profiles, Privacy and current-site controls. Capture profile values when opening sheets.
3. Include file-system storage in bulk site-data clearing and wait for asynchronous completion. Remove global app-permission resets from profile data clearing; website storage and site settings are separate controls.
4. Validate category/search/state behavior with injected backend failures and delays. Use temporary namespaced WebKit stores and a loopback fixture to prove selected-site/category deletion, profile deletion isolation and private-store behavior. Run focused XCTest, pure selfcheck, build and diff checks.
5. Push a codex branch, create and attach the PR, independently review its current diff, fix findings and repeat review, wait for required CI, squash-merge, verify the merge and clean up owned test instances.

Constraints: macOS 26 deployment floor; no private WebKit selectors or filesystem estimates; no changes to another profile; no persisted private data; no blanket process termination. Existing unrelated local work stays intact.
