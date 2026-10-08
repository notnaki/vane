# Reader and Easel workflows implementation plan

Goal: Improve difficult article extraction and reading controls, and make capture annotation discoverable without a second editor.

Architecture: Retain Reader's untrusted node-tree contract and Swift HTML sanitization. Extend the existing persisted preferences and native menus. Keep annotations as ordinary Easel objects over the original image, using the current store and undo history.

Constraints: macOS 26 minimum; validate on this macOS 27.0.1 host. No new dependencies. Profile-owned Easels, private-window restrictions, 8 MiB image and 32 million pixel limits remain. Motion follows Reduce Motion and Battery Saver.

Inspection: Reader already offers size/serif persistence; it drops TABLE and normalizes preformatted text. Easel PRs #204, #240, #271, #276 added local/profile storage, native tabs, tools, cropping, source views and undo. Recent #326 and #328 change browser lifecycle and site styling, so extraction must continue to sanitize output and reject stale entry. Reuse tools and menus.

1. Add WebKit extraction regressions for sibling prose, legacy table layout, data tables, hidden furniture, preformatted code and lazy images. Observe failures, then extend scoring/serialization without relaxing sanitization. Keep probe and extraction counts identical.
2. Add persisted spacing/width and clickable source tests. Observe failures, then add bounded settings, live CSS updates and Reading Preferences in Page Actions and View. Existing text-size/typeface controls remain compatible. Guard Reader entry against navigation during extraction.
3. Add pixel fidelity and annotation persistence/undo/profile regressions. Observe failures, preserve CGImage pixels without thumbnail resizing, select newly captured images, and expose Annotate Image in image properties/context menu. Pause that image's live view and activate the existing pencil/locked tool. Shapes/text remain normal tools; no flattening or grouping introduced.
4. Update README with behavior and limitations. Run focused Reader/Easel/page capture tests, pure selfcheck and a debug app build. Independently review the current PR diff; fix findings, repeat focused validation/review, require passing CI, squash-merge, verify merge and clean up task-owned test processes.

Review focus: long furniture should not beat article prose; tables must preserve readable structure; narrow/high-DPI captures retain native pixels; failed saves must not mutate persisted state; stale async Reader entry must not replace a newly navigated page.
