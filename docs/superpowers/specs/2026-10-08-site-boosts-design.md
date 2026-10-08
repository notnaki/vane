# Site Boosts

## Intent

Add Arc-style website customization to Vane: change fonts and colors, hide
distractions by clicking them, and optionally author CSS and JavaScript. The
user approved the proposed Boost editor on October 8, 2026. Success means a
customization is easy to create while looking at the page, survives normal
navigation and relaunch, and never affects a different website or profile.

## Scope and entry point

Site Controls gains **Boost This Site** for HTTP and HTTPS pages. A site with
an existing Boost offers **Edit Boost**. The action opens a compact, native,
nonmodal editor associated with the current tab; the page remains visible and
interactive. There is one Boost per website per profile in this version.

The editor shows the website being edited and provides:

- An enabled switch, a font picker with a website-default option and a small
  curated set of installed font families, and a text-size control.
- Background, text, and link color controls, with optional overrides,
  coordinated preset swatches, and custom color selection.
- **Zap** to enter click-to-hide mode, a list of hidden elements, and undo.
- Separate CSS and JavaScript editors. CSS previews live. JavaScript requires
  an explicit enable switch and **Apply Script** action.
- **Reset Boost** to remove its settings and restore the website's styles.

Changes save automatically and update matching open tabs in the same profile.
The editor makes it clear when changes are temporary in a private tab. A
navigation to another website closes the editor and ends Zap mode rather than
silently editing the destination under the old site's title.

## Website identity and persistence

A website is keyed by its exact HTTP(S) origin: scheme, lowercase host, and
effective port, with standard ports normalized. Paths, queries, and fragments
are not part of the key. Subdomains remain separate, including `www`; a label
in the editor explains that the Boost applies to this origin. This keeps user
scripts scoped as precisely as the site they were enabled for.

A Codable value stores enabled state, optional font and color overrides,
text-size scale, hidden-element selectors, CSS, JavaScript, and the separate
script-enabled choice. Store a versioned dictionary under a profile-specific
UserDefaults key, following existing per-site settings patterns. An entirely
default value removes the entry. Unknown or malformed records must not cause
a crash or execute code. Profile deletion and site-settings reset remove the
associated Boost records.

Private tabs use their own in-memory values, inherit no persistent scripts,
and save nothing to disk. Their values disappear when the tab closes. Boost
management must not create a web view for a suspended tab merely to update it;
resuming the tab picks up the current saved value.

## WebKit integration

Use public `WKUserContentController`, `WKUserScript`, content-world, and
JavaScript-evaluation APIs. Add Boost support to Vane's existing per-tab
controller setup, including popup and resumed-tab paths. Do not clear or
replace unrelated scripts, message handlers, or content-blocking rules.

Visual customization runs in a dedicated isolated content world. A single
owned style element combines generated font/color/size rules, hidden-element
rules, and custom CSS. Updating or disabling a Boost replaces or removes that
element instead of accumulating styles. The visual script checks the actual
document's origin before applying; redirects cannot carry a previous website's
Boost onto a different origin. Styles must be ready early in document loading
and work after a reload. CSS hiding also covers elements added later by a
single-page application without continuous document scanning.

Optional user JavaScript runs in the page world after document loading so it
can interact with the website's own objects. Execution requires both Boost
and script enablement and an exact origin match. Save/edit does not repeatedly
execute a script on each keystroke; **Apply Script** deliberately runs the
latest code on the current page, and subsequent documents run it once.
Exceptions produce readable feedback without breaking unrelated browser
features. Turning off or resetting a script prevents future execution; the
editor offers a reload to remove arbitrary effects already made to the page.
Live preview never evaluates code against a different document after an
asynchronous navigation.

## Zap interaction

Zap highlights the element under the pointer and intercepts its selection
before the website can activate a link or button. Click records a selector
and hides the element. Prefer a unique escaped ID; otherwise generate a
unique structural selector. Never hide the root document or body. An iframe
is selected as a whole; editing its contents and shadow-root contents are
outside this version's scope.

The user can select several elements, undo the latest selection, or restore
any saved hidden element from the editor. Escape and the editor's **Done**
control leave Zap mode. End selection on navigation, tab closure, editor
closure, and loss of the owning page. Remove highlight overlays and listeners
on every exit path. Only the owning tab may submit selections, and stale
messages from a previous document must not save a selector for the new page.
Selectors can stop matching when a website changes its markup; display the
saved selectors so the user can remove or replace them.

## Motion and accessibility

Use Vane's existing typography, spacing, control styling, and brief motion.
Editor section changes and Zap state changes animate by default. Respect
system Reduce Motion and Battery Saver through the existing motion policy.
Font, color, and enabled controls have accessibility labels. Zap announces
its interaction instructions, supports Escape, and has an editor-based route
to restore hidden elements without pointer selection.

## Components

- `SiteBoosts.swift`: Codable model, origin identity, profile/private storage,
  and coordination of changes across matching live tabs.
- `SiteBoostScripts.swift`: visual runtime, selector picking, and bounded
  user-script construction with explicit origin checks.
- `SiteBoostEditor.swift`: editor presentation, visual controls, CSS/JS
  editors, undo/reset, and script status.
- `SiteControl.swift`: derived Boost row and entry action.
- `Engine.swift`: content-controller setup, message dispatch, and lifecycle
  integration. Profile/site reset code gains narrowly scoped cleanup hooks.

Keep these units focused; do not restructure unrelated browser code.

## Verification and delivery

Add focused XCTest coverage for origin normalization, malformed storage,
profile separation, private lifetimes, disabling/resetting, and serialization.
Use real WKWebView fixtures to verify style application and removal, reload
persistence, cross-origin navigation isolation, CSS handling of dynamically
inserted elements, Zap selection/undo/cleanup, and opt-in script execution and
errors. Tests must use isolated settings and local fixtures.

Build the debug executable, run the relevant tests and pure selfchecks, and
inspect the editor and Zap flow in a task-owned test instance if a graphical
session is available. Track and quit any launched test app before completion.
Update README with entry point, script behavior, and site-matching limits.

Push a `codex/` branch, open a PR, obtain independent review of the latest
diff, fix actionable findings, wait for required CI and approvals, and
squash-merge. Verify the merged PR and commit. Sync local `main` only when
existing work can be preserved.

## Out of scope

Boost sharing, a public gallery, account sync, importing remote scripts,
multiple named Boosts for one origin, wildcard website matching, and scripting
cross-origin frames are not needed for the requested customization flow.
