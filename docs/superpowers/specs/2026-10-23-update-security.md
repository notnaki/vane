# Update and credential security completion

Finish the remaining source-level security work from `docs/SECURITY-AUDIT.md` before release.

- macOS 26 remains the minimum; preserve App Sandbox, Hardened Runtime, signature, Gatekeeper, version and architecture checks.
- The browser must not have general write access to `/Applications/` or `~/Applications/`. Authenticated same-user XPC performs installation, recovery and launch-health cleanup. Read access remains for version and pending-transaction inspection.
- Recovery and health ownership belong to the authenticated browser PID, kernel start time and executable vnode path. Missing, stale, wrong-target and old-inode callers cannot mutate a transaction. A helper PID must never become its launch owner.
- Preserve ordinary local/ad-hoc startup with no transaction, old-version rollback, isolated data directories, crash recovery, concurrent-launch exclusion and detached relaunch supervision.
- Cancel downloads before writing more than 200 MiB, including unknown-length bodies. Reject oversized advertised lengths and untrusted redirect hops; use request/resource timeouts and delete incomplete output.
- Extract ZIP only, streaming actual decompressed output with limits of 1 GiB total, 512 MiB per file, 20,000 entries, 1,024 path bytes, 32 path components and 120 seconds. Reject traversal, ambiguous/colliding names, links and special files. Preserve executable bits, avoid untrusted ownership/ACL/flags, and accept actual release packaging including bounded AppleDouble metadata.
- Always evaluate each supplied certificate trust; do not reuse results based only on the leaf fingerprint.
- Store native GitHub integration tokens separately from web passwords, maintaining profile/test-instance isolation, safe legacy migration, locked-Keychain handling, sign-out and deletion.
- Use focused adversarial tests and signed native/XPC probes. Required CI and independent review must pass on the final commit before squash merge. An unchanged signed/notarized release candidate and clean-Mac/macOS 26 checks remain separate evidence; do not publish a release or claim those passed without running them.
