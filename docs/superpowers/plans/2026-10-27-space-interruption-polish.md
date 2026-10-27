# Space interruption and footer polish

The visible cross-profile footer is replaced with a cached/new SwiftUI hosting root during selection. Its local selected-size state can already equal the new endpoint, so no change animation runs. The destination-store click path also queues origin clicks before reaching reversal handling.

- Reproduce a cross-profile origin click during an unfinished native landing; retarget the same captured pair at its presented position, including repeated reversals. Keep unrelated third-destination rows stable.
- Keep interactive footer controls, menus, hover targets and accessibility in SwiftUI. Move marker ink into a window-owned native presentation keyed by Space ID. Carry the existing glyph layer and animation clock between profile hosts; ignore parked-root updates. Render the existing SF Symbol artwork into a backing image rather than substituting a different glyph.
- Drive emphasis with the sidebar's native timing; keep selection growth independently brief and reversible. End motion immediately under the footer's Reduce Motion/Battery Saver policy.
- Validate native interruption, queued destinations, marker appearance, new/cached profile handoffs, compact/overflow layouts and motion policy. Compare input timings only on an idle desktop. Independently review the final PR, pass required CI, squash-merge and clean up owned test copies/worktree.

The user's primary-checkout Release app is currently open for their own evaluation. Leave it available while developing in the isolated worktree; track any additional test instances separately.
