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
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Look.cardInset) {
                    ForEach(groups.indices, id: \.self) { index in
                        folder(index)
                    }
                }
                .padding(.horizontal, Look.paneMargin)
                .padding(.bottom, Look.cardInset)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 520, height: 540)
        .font(Look.text)
        .foregroundStyle(Look.inkPrimary)
        .background(Look.panelFill)
        .vaneMotionPolicy()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Look.cardInset) {
            Image(systemName: "folder.badge.gearshape")
                .font(Look.icon)
                .foregroundStyle(Look.inkSecondary)
                .frame(width: Look.pillHeight, height: Look.pillHeight)
                .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Look.rowGap) {
                Text("Tidy preview").font(Look.dialogTitle)
                Text("Rename folders and choose the tabs to include.")
                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
            }
        }
        .padding(Look.paneMargin)
        .padding(.bottom, -Look.inset)
    }

    private func folder(_ index: Int) -> some View {
        let tabs = groups[index].tabIDs.compactMap { id in
            store.tabs.first { $0.id == id && !store.isTabLocked(id) }
        }
        let count = tabs.filter { !excluded.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Look.rowSpacing) {
                Image(systemName: "folder")
                    .font(Look.icon).foregroundStyle(Look.inkSecondary)
                    .accessibilityHidden(true)
                TextField("Folder name", text: $groups[index].name)
                    .textFieldStyle(.plain).font(Look.folderTitle)
                    .accessibilityLabel("Group \(index + 1) name")
                    .help("Rename this folder")
                Text("\(count) \(count == 1 ? "tab" : "tabs")")
                    .font(Look.caption).monospacedDigit()
                    .foregroundStyle(Look.inkSecondary)
                    .fixedSize()
            }
            .padding(Look.cardInset)
            .background(Look.controlFill)

            VStack(alignment: .leading, spacing: Look.listRowGap) {
                ForEach(tabs) { tab in
                    TidyPreviewTabRow(tab: tab, included: Binding(
                        get: { !excluded.contains(tab.id) },
                        set: { on in
                            Motion.list {
                                if on { excluded.remove(tab.id) } else { excluded.insert(tab.id) }
                            }
                        }))
                }
                if count < 2 {
                    Label("Choose at least two tabs to create this folder.", systemImage: "info.circle")
                        .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                        .padding(Look.rowInset)
                        .transition(.opacity)
                }
            }
            .padding(Look.inset)
        }
        .background(Look.cardFill)
        .clipShape(.rect(cornerRadius: Look.pillRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Look.pillRadius)
                .strokeBorder(Look.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Look.cardInset) {
            Rectangle().fill(Look.hairline).frame(height: 1)
            if !preview.isCurrent(in: store) {
                Label("Tabs changed. Cancel and run Tidy again.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Look.warning)
            } else if !message.isEmpty {
                Text(message).foregroundStyle(Look.inkSecondary)
            }
            HStack(alignment: .center, spacing: Look.cardInset) {
                VStack(alignment: .leading, spacing: Look.captionGap) {
                    Text("\(proposed.count) folders · \(proposed.flatMap(\.tabIDs).count) tabs")
                        .font(Look.heading).monospacedDigit()
                    Text("Other tabs stay in place.")
                        .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Groups") { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposed.isEmpty || !preview.isCurrent(in: store))
            }
            .controlSize(.large)
        }
        .font(Look.footnote)
        .padding(.horizontal, Look.paneMargin)
        .padding(.bottom, Look.paneMargin)
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

private struct TidyPreviewTabRow: View {
    @ObservedObject var tab: Tab
    @Binding var included: Bool
    @State private var hovered = false

    var body: some View {
        Toggle(isOn: $included) {
            HStack(spacing: Look.rowSpacing) {
                TabIcon(tab: tab, size: Look.rowIcon)
                VStack(alignment: .leading, spacing: Look.captionGap) {
                    Text(TidyTitles.title(for: tab)).font(Look.text)
                        .foregroundStyle(included ? Look.inkPrimary : Look.inkSecondary)
                        .lineLimit(1)
                    Text(tab.currentURL?.host ?? tab.currentURL?.absoluteString ?? "New Tab")
                        .font(Look.caption).foregroundStyle(Look.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(Look.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Look.hovered : .clear, in: .rect(cornerRadius: Look.cardRadius))
        .onHover { value in Motion.animate(Look.quick) { hovered = value } }
        .help(tab.currentURL?.absoluteString ?? "New Tab")
    }
}
