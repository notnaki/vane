# MV3 navigator identity on system WebKit

## Authorization and result

The user explicitly authorized a Yab-like navigator override on 2026-10-31, while retaining Apple's system WebKit. This supersedes the earlier prohibition on navigator overrides in the worker-identity investigation. The user wants issue #513 closed when its exact startup/restart identity behavior is repaired, without requiring universal Chrome compatibility.

MV3 service-worker code must observe Vane's selected identity at its first instruction, including imported module dependencies, after background recreation, and after restoring the accepted installation. Keep the native worker-UA limitation distinct from the repaired JavaScript surface. Remove the advisory exception only after blocking regression coverage passes on the minimum supported macOS CI runtime.

## Implementation direction

Use the selected browser identity (default Safari), rather than unconditionally claiming Chrome. This is the implementer's choice to satisfy the existing selected-UA assertions and avoid making extensions infer Chrome-only capabilities. Preserve both native WebKit API namespaces; map APIs only when their behavior is equivalent and tests demonstrate a need. Do not fabricate unavailable features or grant additional permissions.

System WebKit owns workers, IPC, permissions, stores and execution. Vane supplies a small bootstrap that overrides only the extension worker's navigator UA/appVersion; preserve other navigator facts unless a tested identity rule requires them. Ordinary pages, content scripts, MV2 backgrounds and extension popups keep their current behavior.

The bootstrap must execute before original worker code and all module dependencies. An asynchronous message, a popup update, or a later evaluation is insufficient. Keep original accepted resources and manifests unchanged on disk, including signed Safari bundles. Derive an in-memory resource view for WebKit, overriding the worker entry resource and supplying an extra bootstrap module when necessary. Preserve original vendor resource paths and module-relative imports. Give explicit worker entries a content-version query and generated workers an internal versioned wrapper URL, binding every accepted resource, selected identity and bootstrap implementation. Full entry URLs are intentionally observable and differ; identical restorations are stable. This forces WebKit to update a registration when any input changes. Classic JavaScript directive prologues (especially strict mode), BOMs and comments must retain their semantics. Do not wrap vendor code in a function.

A small guarded Objective-C bridge can use WebKit's existing resource-dictionary initializer. Its unavailable-selector path must fail visibly, never silently run a worker with an unqualified identity. Read resources with anchored descriptors and the existing 64 MB per-file, 256 MB total, 20,000-entry and 64-level limits. Signed sources continue through their existing signature/snapshot verification before derivation; each original Data must also pass SecCodeValidateFileResource against the exact accepted signature before transformation. Resource initialization does not grant native hosts or replace consent. The bootstrap does not attach a runtime message probe or intercept vendor listeners; native tests capture first-instruction values. Failure to set the prototype throws before vendor code executes, and normal startup remains owned by WebKit.

The identity is a snapshot for one loaded extension context. A Develop identity change must rederive/reload MV3 contexts with unchanged native controller, context identity/origin, storage, and explicit runtime access decisions. Coalesce overlapping changes and respect installation/removal lifetimes. New worker births must not keep the prior selection after settlement. Verify idle termination/wakeup of the same context separately from full host restoration.

Handle explicit service_worker entries and WebKit-generated MV3 workers from background.scripts plus preferred_environment. For generated workers, provide an equivalent versioned classic/module import wrapper rather than overriding WebKit's reserved generated resource. Vendor script resources and URLs remain unchanged. Gate the bootstrap to actual ServiceWorkerGlobalScope instances even when a worker resource is reused elsewhere. Obtain the selected value from ExtensionUserAgent's effective fallback, so pages and worker agree when native page-UA SPI is unavailable.

## Invariants and proof

- Keep controllers, profile/data-store ownership, context IDs, origins and accepted access unchanged; storage survives reload/restore.
- Fail closed on unsafe resource paths, missing worker resources, unsupported initializer or malformed bootstrap inputs.
- Classic first-instruction UA, module dependency first-instruction UA, default/custom identities, worker recreation and host restoration must be blocking native tests.
- Verify source bytes are unchanged and neither ordinary webpages nor content scripts receive the worker override.
- Exercise native chrome/browser messaging and storage from the worker to establish that no API remap is needed for those equivalent namespaces.
- Test strict/sloppy classic semantics, imports/relative URLs, duplicate bootstrap behavior and the API-unavailable path.
- Run relevant extension lifecycle, compatibility, native-messaging-denial and ownership tests. Real-package acceptance is scoped to the packages/workflows actually exercised; do not infer universal compatibility.

## Delivery

Implement and validate in an isolated codex branch. Obtain independent current-diff review and address actionable findings. Required CI must pass against the current target before squash merge. Preserve every native failure and cleanup record; do not retry an unexplained assertion failure into a pass. Keep required branch protection intact. Retire task-owned test instances and archive the task worktree after verified merge.
