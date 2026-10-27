import SwiftUI

/// Small outlines keep their controls warm. A folder changes the slots' geometry,
/// not the lifetime of every tooltip, focus target and drag destination inside it.
/// Medium outlines eagerly mount only visible rows under a captured structural bound.
/// Larger outlines keep the existing lazy mounting path.
struct SidebarSectionRows<Content: View>: View {
    @State private var buffersRows = BufferedSidebarRowsExperiment.enabled
    @State private var virtualizesRetainedRows = RetainedRowVirtualizationExperiment.enabled
    @Environment(\.nativeCachedSidebarBatches) private var groupedNativeRows
    @Environment(\.sidebarNativeReadinessScope) private var nativeReadinessScope
    @ObservedObject private var dragging = Dragging.shared
    @SidebarObserved var store: TabStore
    let snapshot: Feel02SidebarRowsCache.Snapshot
    var readinessSection: String? = nil
    var collapsed = false
    let transition: AnyTransition
    @ViewBuilder let content: (SidebarRows.Row, Int, Int) -> Content

    private var editingRows: Set<String> {
        var result = Set([store.renamingFolder?.uuidString].compactMap { $0 })
        if let pane = store.renamingTab {
            let leads = SidebarRows.splitLeads(tabs: store.accessibleTabs, splits: store.splits)
            result.insert((leads[pane] ?? pane).uuidString)
        }
        return result
    }

    var body: some View {
        let rows = collapsed ? [] : snapshot.rows
        if groupedNativeRows || NativeCachedSidebarBatchesExperiment.enabled {
            NativeCachedSidebarBatchSectionRows(rows: rows, modelIDs: snapshot.structuralRowIDs,
                protectedRows: editingRows.union(Set([dragging.tab?.uuidString, dragging.folder?.uuidString].compactMap { $0 })),
                readinessSection: readinessSection, owner: store) { row, index, total in
                    // Each native owner is a separate hosting root. Row menus
                    // need the real store explicitly, without transplanting the
                    // outer host's private focus or presentation environment.
                    content(row, index, total).environmentObject(store)
                }
                .environment(\.sidebarNativeReadinessScope, nativeReadinessScope
                    ?? SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID))
        } else if buffersRows && snapshot.retainedRows == nil {
            BufferedSidebarSectionRows(rows: rows,
                editingRows: editingRows,
                content: content)
        } else if let retained = snapshot.retainedRows, !virtualizesRetainedRows {
            let indices = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            VStack(spacing: 0) {
                ForEach(retained) { row in
                    let shown = indices[row.id] != nil
                    content(row, indices[row.id] ?? 0, rows.count)
                        .frame(height: Look.rowHeight)
                        // The slot owns disclosure geometry. A height-changing removal
                        // transition would impose its identity height even while hidden.
                        .transition(.opacity)
                        .frame(height: shown ? Look.rowHeight : 0, alignment: .top)
                        .clipped()
                        .opacity(shown ? 1 : 0)
                        .padding(.bottom, shown ? Look.rowGap : 0)
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                        .onChange(of: shown) { _, shown in
                            guard !shown else { return }
                            if store.renamingTab == row.tab?.id { store.renamingTab = nil }
                            if store.renamingFolder?.uuidString == row.id { store.renamingFolder = nil }
                        }
                }
            }
            .environment(\.sidebarRetainsControls, true)
            .padding(.bottom, rows.isEmpty ? 0 : -Look.rowGap)
            .vaneMotionPolicy()
        } else if snapshot.retainedRows == nil && snapshot.eagerlyMountsVisibleRows {
            VStack(spacing: Look.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    content(row, index, rows.count).transition(transition)
                }
            }
        } else {
            LazyVStack(spacing: Look.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    content(row, index, rows.count).transition(transition)
                }
            }
        }
    }
}
