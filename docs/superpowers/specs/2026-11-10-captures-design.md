# Arc-like page captures

Extend Vane’s existing ⌘⇧2 region/element capture with full-page output and a shared compact action menu. Preserve native copy, PNG export, sharing and Easel output; add retake and crop/markup editing. User feedback explicitly requires rounded selection corners, immediate element highlighting, and a menu that fits its content without a bulky heading or empty footer.

The editor supports crop, pen, arrows, rectangles, text, colors and stroke widths, undo/redo, reset, cancel/apply and Fit/100%/200% zoom. Export retains original image resolution.

The user clarified that Save to Library must follow Arc: captures appear in the existing Library → Media view, alongside other saved pictures. Do not add a separate Captures section. Reuse the downloads/media saved-file pipeline and its existing history policy, with explicit PNG persistence only. Private captures stay temporary and cannot enter Media or Easels.

Use native AppKit/SwiftUI/WebKit/PDFKit, no dependencies. Full-page rendering includes loaded offscreen content without scrolling or resizing the live tab. Bound bitmap sizes with useful errors. Coalesce hover requests without a pointer-idle debounce. Honor Reduce Motion and Battery Saver. Invalidate stale results on page, tab, window or profile changes.

User stopping point: provide a reviewed, validated test build and open PR, and do not merge before the user tests it.
