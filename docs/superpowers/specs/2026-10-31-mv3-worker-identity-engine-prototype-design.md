# MV3 worker identity: native engine prototype

## Requested result

Fix #513 so an MV3 extension worker has Vane's selected user agent at its first script instruction. Keep #484's completed Bitwarden repair and the compact extension windows intact. A page-only UA override, a passing advisory sample, rewriting an extension, or retrying a worker after it already executed with the wrong identity does not satisfy this result.

## Evidence and corrected assumptions

The recorded macOS26.6.2 / system WebKit21624.5.1.11.3 failure has matching native/background-view/popup Safari identities but bare WebKit worker startup and current identities. The exact internal origin lookup/publication ordering was not captured. Do not claim that an origin lookup miss or a particular IPC race was proven.

Root reviewed the user messages in this chat. The previous claim that the user explicitly prohibited a WebKit fork or repackaging was not supported by those messages. That attribution must not be used as an approval or a restriction. Vane currently uses system WebKit; replacing that runtime remains a substantial architecture decision.

A new local SDK probe disproved a configuration-copy hypothesis: assigning defaultWebpagePreferences retained the preference object, and the configured private native UA value followed later mutation on the tested macOS27 runtime. It is not a fix and does not establish macOS26 behavior.

## Concrete candidate

Investigate a narrowly scoped native WebKit change at service-worker construction. The pinned source is26695efdefc6076049ec50713a2c4e54b90b4d47. In WebSWContextManagerConnection::installServiceWorker, the existing main-run-loop block can resolve the exact hosting Document named by contextData.serviceWorkerPageIdentifier. Snapshot that document's native Document::userAgent(document.url()) after validating its current frame/page, special service-worker-page role, and origin/partition ownership.

Use a valid snapshot for both the worker frame-loader client and the service-worker thread proxy before extension code starts, including when the incoming cached UA is non-null but stale. Do not substitute the connection-level identifier or the page's main document: a context connection can serve more than one worker host. Do not enumerate unrelated documents or retain the document across asynchronous work.

Preserve the current origin-map then connection-default path for ordinary workers and unavailable/invalid special hosts. Do not resurrect a closed host. This is a candidate based on source review, not a demonstrated repair of the proprietary system binary. It does not promise live updates to an already-running worker after a Develop change; new worker births must use the new selection.

## Prototype boundary and security

The proposed next step is an isolated, locally built engine prototype, not a switch to a custom engine in production. Keep the production app and system frameworks untouched. Preserve macOS26 deployment support, profiles, controller/context identities, permissions, website-data-store ownership, extension origins, and the vendor extension's original bytes.

Keep App Sandbox and Hardened Runtime enabled. Do not disable library validation, enable get-task-allow, change SIP, inject into Apple processes, or add filesystem/native-app privileges. Sign the test app, framework, and helper processes using the existing task signing setup. If the candidate cannot run with these constraints, report that failure rather than relaxing them. Track exact app paths, PIDs, and kernel start times, then retire their exact processes/stores.

Before a production decision, a bundled engine would also need a reproducible build, source/license provenance, signed packaging and updates, and an ongoing engine security-update policy. Prototype approval does not approve that production migration or publishing an upstream fork/issue.

## Required proof

1. Write a deterministic engine regression that supplies wrong incoming and connection-fallback UAs while the exact special hosting document has the selected native UA. The original selection must fail and the candidate must pass; lucky launch repetitions are insufficient.
2. Capture worker UA at script top level before diagnostic messages/getters. Cover classic and module workers and a new worker birth after changing the selected identity.
3. Exercise two special hosts with different identities in the relevant connection scope. Each worker must select its own document.
4. Missing/closed/wrong-origin hosts must not borrow an unrelated document, crash, or extend ownership. Ordinary service-worker behavior must retain its previous semantics.
5. Run the signed normal-app acceptance on an affected macOS26 runner. Attest the actually loaded framework path/hash/version; verify pool/store/context/origin ownership before evaluating UA. Preserve every attempt and every primary/cleanup failure. No vendor-code or navigator-property replacement.

A successful prototype permits a separate reviewed production plan. It does not close #513 automatically. Keep the current system-engine limitation visible until a supported shipping repair passes required CI and actual-main verification. The separate historical navigation-stall CI investigation remains separate from the MV3 result.

## Decision needed

Approve or decline building this isolated native-engine prototype. The major choice is whether to investigate a bundled engine as a possible shipping path, accepting its packaging and security-maintenance implications. No production runtime change is included in this approval.
