import SwiftUI

struct TabOrganizationSheet: View {
    @ObservedObject var store: TabStore
    @StateObject private var model: TabOrganization
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var duplicatesOnly = false
    @State private var spaceFilter: UUID?

    init(store: TabStore) {
        self.store = store
        _model = StateObject(wrappedValue: TabOrganization(store: store))
    }

    private func matches(_ row: TabOrganization.Row) -> Bool {
        (spaceFilter == nil || row.spaceID == spaceFilter)
            && (query.isEmpty || (row.title + " " + row.url.absoluteString + " " + row.spaceName)
                .localizedCaseInsensitiveContains(query))
    }
    private var shown: [TabOrganization.Row] {
        let duplicates = Set(model.duplicateGroups.flatMap(\.rows).map(\.id))
        let ordered = duplicatesOnly ? model.duplicateGroups.flatMap(\.rows) : model.rows
        return ordered.filter { matches($0) && (!duplicatesOnly || duplicates.contains($0.id)) }
    }
    private var selected: [TabOrganization.Row] {
        model.rows.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organize Tabs").font(.title2.weight(.semibold))
                    Text("\(store.profile.name) · \(model.spaces.count) Spaces")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Refresh") { model.refresh() }
            }
            HStack {
                TextField("Search tabs, links, or Spaces", text: $query).textFieldStyle(.roundedBorder)
                Picker("Space", selection: $spaceFilter) {
                    Text("All Spaces").tag(UUID?.none)
                    ForEach(model.spaces) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 170)
            }
            HStack {
                Toggle("Duplicates only", isOn: Binding(get: { duplicatesOnly }, set: { value in
                    Motion.list { duplicatesOnly = value; model.selection = [] }
                })).toggleStyle(.checkbox)
                Text("\(model.duplicateGroups.count) duplicate groups").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if duplicatesOnly {
                    Button("Select Extras") {
                        model.selectDuplicateExtras()
                        model.selection.formIntersection(Set(shown.map(\.id)))
                    }
                } else {
                    Button("Select Shown") {
                        Motion.list { model.selection = Set(shown.filter(\.canChange).map(\.id)) }
                    }
                }
                Button("Deselect") { Motion.list { model.selection = [] } }.disabled(model.selection.isEmpty)
            }
            Text("Pinned tabs, favourites, split panes, and tabs in locked folders are protected. Duplicate matches use the complete URL.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if shown.isEmpty {
                        Text(duplicatesOnly ? "No duplicate tabs match these filters." : "No tabs match these filters.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(shown) { row in
                        Toggle(isOn: Binding(get: { model.selection.contains(row.id) }, set: { on in
                            Motion.list {
                                if on { model.selection.insert(row.id) } else { model.selection.remove(row.id) }
                            }
                        })) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title).lineLimit(1)
                                    Text(row.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(row.spaceName).font(.caption).foregroundStyle(.secondary)
                                    if !row.canChange {
                                        Text(row.kind == .today ? "Split View" : TabMenu.name(row.kind))
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else if row.named {
                                        Text("Custom name").font(.caption).foregroundStyle(.secondary)
                                    } else if row.active {
                                        Text("In use").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .toggleStyle(.checkbox).disabled(!row.canChange)
                        .padding(10)
                        .background(model.selection.contains(row.id) ? Look.selected : Look.controlFill,
                                    in: .rect(cornerRadius: Look.pillRadius))
                        .accessibilityLabel("\(row.title), \(row.spaceName)\(row.canChange ? "" : ", protected")")
                        .help(row.url.absoluteString)
                    }
                }.padding(2)
            }
            .animation(Motion.reduced ? nil : Look.list, value: shown.map(\.id))
            if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Text("\(model.selection.count) selected").font(.callout).foregroundStyle(.secondary)
                Button("Copy Links") { copyLinks() }.disabled(selected.isEmpty)
                Menu("Move to Space") {
                    ForEach(model.spaces) { space in
                        Button(space.name) { model.moveSelected(to: space.id) }
                            .disabled(!selected.contains { $0.spaceID != space.id })
                    }
                }.disabled(selected.isEmpty)
                Button(duplicatesOnly ? "Archive Selected Copies" : "Archive Selected") {
                    model.archiveSelected(duplicatesOnly: duplicatesOnly)
                }.disabled(selected.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 760, height: 580)
        .onChange(of: spaceFilter) { Motion.list { model.selection = [] } }
        .onChange(of: query) { Motion.list { model.selection = [] } }
    }

    private func copyLinks() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.map { $0.url.absoluteString }.joined(separator: "\n"), forType: .string)
        model.message = "Copied \(selected.count) links."
    }
}
