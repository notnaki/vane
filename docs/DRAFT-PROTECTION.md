# Unfinished work and tab suspension

Vane keeps live pages when you change tabs, switch Spaces, or change which regular
window owns a shared tab. Those transitions retain the same WebView and document;
they do not serialize and reconstruct your form. Private windows keep their own
pages and are excluded from automatic tab suspension. Separate profiles do not
share detector state or live pages.

The idle sweep, Battery Saver and memory-pressure handler use the same draft and
media protections. Battery Saver shortens the idle threshold to at most five
minutes; memory pressure ignores the idle threshold. Neither weakens draft,
selection, private-browsing, loading or media protections. A tab selected in any
window, including a split pane, stays live.

Before suspending an eligible background page, Vane queries scripts in an isolated
content world in the main document and embedded frames, including cross-origin
frames. Text inputs and textareas are compared with their original values, so
clearing a prefilled field counts as work. Rich-text/contenteditable markup is
compared with its baseline at the first editing intent; asynchronous hydration of
untouched editors does not count as work. Dynamically inserted controls and open shadow
roots are scanned too. Returning a field/editor to its original value releases
protection. An actual uncancelled reset establishes a new baseline for that form. A submit event,
including a cancelled submit common in single-page applications, does not prove
that a server accepted the draft. A completed submission navigation receives a
fresh document and baseline. SPA URL changes retain the current document's state.
Removed controls with outstanding edits are conservatively retained in the
detector until reset, reversion or document replacement.

Missing scripts, inaccessible/unregistered frames, a failed or timed-out query,
and document changes during a query defer that suspension attempt. Subsequent
passes retry detection. Detached frame handles are discarded conservatively;
remaining live frame counts must still match before suspension can proceed.
A second pass revalidates each child document and its draft state.
After asynchronous checks, Vane revalidates document generation, WebView, tab
ownership, selection/activity, loading, media, suspension preferences and the
current Battery Saver threshold. Only one suspension attempt runs per live tab.

## Privacy and limits

Original values and editor markup live only inside the document's isolated script
world. Native messages and query results contain random document tokens, frame
handles, child-frame counts and dirty booleans. Vane does not log field contents,
write draft files, add draft data to backups, or use cross-profile draft caches.
Private browsing uses the same detector without persisting its contents.

This protects live documents, not a recoverable draft archive. WebKit interaction
state and Vane session/Space snapshots preserve navigation and scroll state; they
are **not a reliable backup of form fields, rich-editor state, file selections,
or JavaScript-only drafts**. Work held only in memory cannot be recovered after
a WebContent process crash, application crash/force quit, restart, or explicit
page/tab close/navigation. A site's own autosave may recover it, but Vane cannot
guarantee that. Folder locking explicitly parks pages for access protection and
can also discard volatile form/editor state.

Editors that keep work only in JavaScript, canvas or inaccessible closed shadow
roots cannot reliably be identified from the DOM. Rich editors that change markup
without emitting editing events cannot reliably distinguish drafts from initial
hydration. Sites may replace the DOM or
reset controls before saving; Vane cannot infer remote save success. A retained
removed control or cancelled SPA submission can therefore keep a page awake until
the document is replaced. Prefer the site's save/export action for valuable work.

## Synthetic validation on macOS 27

```sh
swift test --filter 'DraftProtectionTests|BatterySaverTests|SharedPresentationTests|SpaceSelectionContinuityTests|SpaceLayoutRestoreTests'
./.build/debug/vane selfcheck --pure
```

Fixtures use disposable profiles/private stores, local simulated documents and
loopback HTTP. They cover cleared and reverted fields, textareas, rich editors,
open shadow roots, dynamic fields, same/cross-origin frames, SPA routes, cancelled
and completed submissions, resets, tab/Space/window retention, detection failures
and retries, idle/Battery Saver/pressure protection and asynchronous ownership,
selection and same-URL document replacement. No personal forms or credentials are
used.
