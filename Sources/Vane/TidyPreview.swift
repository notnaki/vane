import SwiftUI

/// Frozen input and its Space travel together through the async grouping request.
@MainActor struct TidyPreview: Identifiable {
    let id = UUID()
    let space: UUID?
    let profile: UUID
    let pages: [UUID: URL?]
    var groups: [TidyTabs.Group] = []

    init(store: TabStore) {
        space = store.currentSpaceID
        profile = store.profileID
        let eligible = Set(TidyTabs.candidates(in: store).map(\.id))
        pages = Dictionary(uniqueKeysWithValues: store.tabs.filter { eligible.contains($0.id) }
            .map { ($0.id, $0.currentURL) })
    }

    func isCurrent(in store: TabStore) -> Bool {
        guard !store.isPrivate, !store.isLittle, profile == store.profileID,
              space == store.currentSpaceID else { return false }
        let eligible = Set(TidyTabs.candidates(in: store).map(\.id))
        return pages.allSatisfy { id, page in
            eligible.contains(id) && store.tabs.first { $0.id == id }?.currentURL == page
        }
    }
}

struct TidyPreviewSheet: View {
    @ObservedObject var store: TabStore
    let preview: TidyPreview
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [TidyTabs.Group]
    @State private var excluded = Set<UUID>()
    @State private var message = ""

    init(store: TabStore, preview: TidyPreview) {
        self.store = store
        self.preview = preview
        _groups = State(initialValue: preview.groups)
    }

    private var proposed: [TidyTabs.Group] {
        TidyTabs.reviewed(groups.map {
            .init(name: $0.name, tabIDs: $0.tabIDs.filter { !excluded.contains($0) })
        }, in: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Tidy").font(.title2.weight(.semibold))
            Text("Rename groups or untick tabs to leave them where they are. Groups need at least two tabs.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Folder name", text: $groups[index].name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Group \(index + 1) name")
                            ForEach(groups[index].tabIDs, id: \.self) { id in
                                if let tab = store.tabs.first(where: { $0.id == id }),
                                   !store.isTabLocked(id) {
                                    Toggle(isOn: Binding(get: { !excluded.contains(id) }, set: { on in
                                        Motion.list {
                                            if on { excluded.remove(id) } else { excluded.insert(id) }
                                        }
                                    })) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(TidyTitles.title(for: tab)).lineLimit(1)
                                            Text(tab.currentURL?.absoluteString ?? "New Tab")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }.padding(2)
            }
            Text(message.isEmpty
                 ? "\(proposed.count) folders · \(proposed.flatMap(\.tabIDs).count) tabs. Other tabs stay in place."
                 : message)
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Groups") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposed.isEmpty || !preview.isCurrent(in: store))
            }
            if !preview.isCurrent(in: store) {
                Text("Tabs changed since this proposal. Cancel and run Tidy again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 520, height: 540)
    }

    private func apply() {
        guard preview.isCurrent(in: store) else {
            message = "Tabs changed since this proposal. Cancel and run Tidy again."
            return
        }
        let count = TidyTabs.apply(proposed, to: store)
        guard count > 0 else { message = "Nothing to tidy"; return }
        dismiss()
        rebuild()
        Toasts.show("Tidied into \(count) folders", action: ("Undo", { [weak store] in
            guard let store else { return }
            TidyTabs.undo(store)
            rebuild()
        }), in: store)
    }
}
