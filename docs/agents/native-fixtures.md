# Native regression fixtures

- Before native regression actions, admit the required AppKit loop, foreground/document state, and exact visible presentation owner. Use bounded observable prerequisites instead of guessed readiness sleeps. Preserve outcome assertions/deadlines; never await the desired outcome before an early-animation sample.
