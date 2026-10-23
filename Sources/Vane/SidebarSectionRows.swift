import SwiftUI

/// Small outlines keep their controls warm. A folder changes the slots' geometry,
/// not the lifetime of every tooltip, focus target and drag destination inside it.
/// The cache supplies no retained rows for a large outline, preserving virtualization.
struct SidebarSectionRows<Content: View>: View {
    @SidebarObserved var store: TabStore
    let snapshot: Feel02SidebarRowsCache.Snapshot
    var collapsed = false
    let transition: AnyTransition
    @ViewBuilder let content: (SidebarRows.Row, Int, Int) -> Content

    var body: some View {
        let rows = collapsed ? [] : snapshot.rows
        if let retained = snapshot.retainedRows {
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
        } else {
            LazyVStack(spacing: Look.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    content(row, index, rows.count).transition(transition)
                }
            }
        }
    }
}
