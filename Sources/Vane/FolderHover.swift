import SwiftUI

/// Arc's collapsed-folder hover: a search field over the folder's tabs, each with when it
/// was last visited. Opens beside the row in the favourite preview's child panel, so the
/// hover never takes focus from the page; clicking the field does.
struct FolderHoverList: View {
    let store: TabStore
    let folder: Folder
    let tabs: [Tab]
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var visited: [Tab.ID: Date] = [:]

    static let rowHeight: CGFloat = 46
    nonisolated static func matches(_ titles: [String], _ query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return titles.indices.filter { q.isEmpty || titles[$0].localizedCaseInsensitiveContains(q) }
    }

    private var shown: [Tab] {
        Self.matches(tabs.map(TidyTitles.title(for:)), query).map { tabs[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Look.inkSecondary)
                TextField("Search \(folder.shownName)…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = shown.first { open(first) } }
            }
            .font(Look.rowTitle)
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shown) { tab in
                        FolderHoverRow(tab: tab, date: visited[tab.id]) { open(tab) }
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
            // ponytail: height is fixed by the unfiltered count; the panel sizes once on open.
            .frame(height: CGFloat(min(max(tabs.count, 1), 7)) * Self.rowHeight + 8)
        }
        .frame(width: 260)
        .background(colorScheme == .dark ? Color(white: 0.16) : Color(nsColor: .windowBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        .onAppear {
            // ponytail: one indexed lookup per tab on open; batch it if folders get huge.
            for tab in tabs {
                if let url = tab.homeURL ?? tab.currentURL { visited[tab.id] = store.history.lastVisit(to: url) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs in \(folder.shownName)")
    }

    private func open(_ tab: Tab) {
        close()
        let previous = store.activePageResponder
        store.current = tab.id
        store.focusPage(from: previous)
    }
}

private struct FolderHoverRow: View {
    @ObservedObject var tab: Tab
    let date: Date?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                TabIcon(tab: tab)
                VStack(alignment: .leading, spacing: 1) {
                    Text(TidyTitles.title(for: tab)).font(Look.rowTitle)
                        .foregroundStyle(Look.inkPrimary).lineLimit(1)
                    if let date {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(Look.small).foregroundStyle(Look.inkTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: FolderHoverList.rowHeight).contentShape(.rect)
            .background(hovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovered)
    }
}

extension FolderHoverList {
    nonisolated static func check() -> [(String, Bool)] {
        [("folder hover: empty query keeps every tab", matches(["A", "b"], " ") == [0, 1]),
         ("folder hover: search ignores case", matches(["Coolors", "Sunum"], "sun") == [1])]
    }
}
