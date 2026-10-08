import SwiftUI

struct SpaceTemplatesSheet: View {
    @ObservedObject var store: TabStore
    @StateObject private var model: WorkspaceTemplateModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var rename = ""
    @State private var confirmingDelete = false
    @State private var confirmingUpdate = false
    @State private var replacing = false

    init(store: TabStore, request: WorkspaceSheetRequest) {
        self.store = store
        _model = StateObject(wrappedValue: WorkspaceTemplateModel(store: store, request: request))
    }
    private var validName: Bool { (1...200).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    private var needsAuthentication: Bool {
        model.preview?.protectedFolders.contains { !model.unlocked.contains($0.id) } ?? false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Templates").font(.title2.weight(.semibold))
                    Text("Saved workspaces for \(store.profile.name)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.reload(); if model.saving { model.refreshSource() } }.disabled(model.busy)
                Button("Done") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 18) {
                templateList.frame(width: 190)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if model.saving {
                        Text(replacing ? "Update from Current Space" : "Save Current Space").font(.headline)
                    } else if let selected = model.selected {
                        HStack {
                            TextField("Template name", text: $rename).textFieldStyle(.roundedBorder)
                            Button("Rename") { model.rename(name: rename) }.disabled(model.busy || rename == selected.name)
                        }
                        Text(selected.modified, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let layout = model.preview {
                        if needsAuthentication {
                            HStack {
                                Label("Locked contents are hidden", systemImage: "lock")
                                Spacer()
                                Button("Authenticate…") { model.unlockPreview() }.disabled(model.busy)
                            }.font(.callout)
                        }
                        WorkspaceContentsPreview(layout: layout, unlocked: model.unlocked)
                        if layout.omitted > 0 {
                            Text("\(layout.omitted) blank, file, or local document tab(s) are excluded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.saving && replacing {
                            HStack {
                                Button("Cancel Update") { replacing = false; if let selected = model.selected { model.select(selected) } }
                                Spacer()
                                Button("Replace Template") { confirmingUpdate = true }.disabled(model.busy)
                            }
                        } else {
                            HStack {
                                TextField(model.saving ? "Template name" : "New Space name", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { primaryAction() }
                                Button(model.saving ? "Save Template" : "Create Space") { primaryAction() }
                                    .buttonStyle(.borderedProminent).disabled(!validName || model.busy)
                            }
                        }
                        if !model.saving {
                            HStack {
                                Button("Update from Current Space…") {
                                    replacing = true; model.beginSaving()
                                }.disabled(model.busy || store.currentSpaceID != model.request.sourceID)
                                Spacer()
                                Button("Delete Template…", role: .destructive) { confirmingDelete = true }.disabled(model.busy)
                            }
                        }
                    } else {
                        ContentUnavailableView("No setup selected", systemImage: "rectangle.stack",
                            description: Text("Save your current Space, or choose a template on the left."))
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: model.selection)
                .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: model.saving)
            }.frame(minHeight: 350)
            if model.busy { ProgressView("Authenticating…").controlSize(.small) }
            if !model.message.isEmpty {
                Text(model.message).foregroundStyle(.red).font(.callout)
                    .accessibilityLabel("Template error: \(model.message)")
            }
            if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundStyle(.secondary) }
            Text("Saves layout and page addresses. Cookies, passwords, and signed-in sessions are not copied. Pages use this profile’s existing sign-ins when opened. Live folders become ordinary folders; Favourites stay shared.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(width: 780)
        .onAppear { name = store.currentSpace?.name ?? ""; rename = model.selected?.name ?? "" }
        .onChange(of: model.selection) { rename = model.selected?.name ?? ""; name = model.selected?.name ?? "" }
        .onChange(of: model.saving) { if model.saving { name = store.currentSpace?.name ?? "" } }
        .onChange(of: store.currentSpaceID) { model.cancel(); dismiss() }
        .onChange(of: store.isParked) { if store.isParked { model.cancel(); dismiss() } }
        .onDisappear { model.cancel() }
        .alert("Delete this template?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Spaces already created from it will remain.") }
        .alert("Replace this template’s contents?", isPresented: $confirmingUpdate) {
            Button("Replace") { model.update(); if !model.saving { replacing = false } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The previewed setup will replace the saved contents. Its name stays the same.") }
    }
    private var templateList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { replacing = false; model.beginSaving() } label: {
                Label("Save Current Space…", systemImage: "plus.rectangle.on.rectangle")
            }.disabled(model.busy || model.request.sourceID == nil)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.templates) { template in
                        Button { replacing = false; model.select(template) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.name).lineLimit(2)
                                Text("\(template.layout.tabs.count) tabs · \(template.layout.splits.count) splits")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(!model.saving && model.selection == template.id ? Look.selected : Look.controlFill,
                                            in: .rect(cornerRadius: Look.pillRadius))
                        }.buttonStyle(.plain).disabled(model.busy)
                            .accessibilityLabel("Template \(template.name), \(template.layout.tabs.count) tabs")
                    }
                    if model.templates.isEmpty {
                        Text("No saved templates yet.").foregroundStyle(.secondary).font(.callout).padding(.top, 12)
                    }
                }
            }
        }
    }
    private func primaryAction() {
        guard validName, !model.busy else { return }
        if model.saving {
            if replacing { confirmingUpdate = true } else { model.save(name: name) }
        } else {
            model.create(name: name) { space in
                model.cancel(); dismiss()
                DispatchQueue.main.async { store.switchTo(space: space); Toasts.show("Space created from template", in: store) }
            }
        }
    }
}

struct WorkspaceContentsPreview: View {
    let layout: SpaceLayout
    let unlocked: Set<UUID>
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Pinned", shape: layout.pins)
                section("Today", shape: layout.today)
                if !layout.splits.isEmpty {
                    Text("Split Layouts").font(.headline).padding(.top, 6)
                    ForEach(Array(layout.splits.enumerated()), id: \.offset) { _, split in
                        let names = (split.ids ?? []).compactMap { id in layout.tabs.first { $0.id.uuidString == id } }
                        if names.allSatisfy({ accessible($0.id.uuidString) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("\(names.count) panes · \(split.vertical ? "Stacked" : "Side by side")",
                                      systemImage: split.vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                                Text(names.map { title($0) }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let weights = split.weights {
                                    Text(weights.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: " / "))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        } else { Label("Locked split contents", systemImage: "lock").foregroundStyle(.secondary) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(height: 280)
        .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace contents preview")
    }
    private func accessible(_ id: String) -> Bool {
        layout.pins.lockedFolders(for: id, unlocked: unlocked).isEmpty
            && layout.today.lockedFolders(for: id, unlocked: unlocked).isEmpty
    }
    private func title(_ page: SpaceLayout.Page) -> String {
        page.customName.flatMap { $0.isEmpty ? nil : $0 } ?? page.title
    }
    @ViewBuilder private func section(_ name: String, shape: Pins) -> some View {
        Text(name).font(.headline)
        if shape.entries.isEmpty { Text("No tabs or folders").font(.caption).foregroundStyle(.secondary) }
        ForEach(shape.entries) { entry in
            // Show a locked folder's own label, never its descendants.
            let ancestors = shape.ancestors(of: shape.index(of: entry.id) ?? 0)
            if ancestors.allSatisfy({ shape.folder($0)?.requiresAuthentication != true || unlocked.contains($0) }) {
                HStack(alignment: .top, spacing: 8) {
                    if let folder = entry.folder {
                        Label(folder.name, systemImage: folder.requiresAuthentication == true ? "lock" : "folder")
                            .font(.callout.weight(.medium))
                    } else if let page = layout.tabs.first(where: { $0.id.uuidString == entry.tab }), accessible(entry.id) {
                        Image(systemName: page.kind == .pinned ? "pin" : "globe").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(page)).lineLimit(1)
                            Text(SpaceLayout.templateURL(page.url)?.absoluteString ?? "Local document (excluded)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.padding(.leading, CGFloat(ancestors.count) * 14)
            }
        }
    }
}
