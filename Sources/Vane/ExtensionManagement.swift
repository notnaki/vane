import AppKit
import SwiftUI
import WebKit

@MainActor enum ExtensionManagement {
    private static var windows: [UUID: NSWindow] = [:]
    static let searchRequest = Notification.Name("VaneExtensionManagerSearch")
    fileprivate static let presentationRequest = Notification.Name("VaneExtensionManagerPresentation")

    static func isVisible(for profileID: UUID) -> Bool { windows[profileID]?.isVisible == true }

    /// The browser Find command otherwise consumes Command-F before SwiftUI receives it.
    static func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, NSApp.modalWindow == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "f",
              let window = event.window, window.attachedSheet == nil,
              let profileID = windows.first(where: { $0.value === window })?.key else { return false }
        NotificationCenter.default.post(name: searchRequest, object: profileID)
        return true
    }

    static func show(for host: ExtensionHost = .shared) {
        if let window = windows[host.profileID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            NotificationCenter.default.post(name: presentationRequest, object: host.profileID)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let profile = ProfileManager.shared.profiles.first { $0.id == host.profileID }?.name
            ?? (host.profileID == Profile.incognito.id ? "Private" : "Profile")
        window.title = "Extensions — " + profile
        SecondaryWindowStyle.apply(to: window)
        window.minSize = NSSize(width: 460, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = SecondaryWindowStyle.host(ExtensionManagementView(host: host)
            .font(Look.text).defaultAppStorage(.vane), minimumSize: NSSize(width: 460, height: 450))
        let frameName = "ExtensionManager." + host.profileID.uuidString
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        windows[host.profileID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NotificationCenter.default.post(name: presentationRequest, object: host.profileID)
    }

    static func close(for profileID: UUID) {
        windows.removeValue(forKey: profileID)?.close()
    }

    static func showDetails(_ detail: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        text.isEditable = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = detail
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}

private struct ExtensionManagementView: View {
    @ObservedObject var host: ExtensionHost
    @State private var query = ""
    @State private var filter = ExtensionManagerModel.Filter.all
    @State private var selected: String?
    @State private var importBusy = false
    // ExtensionHost.entries reads manifests and builds runtime diagnostics. Snapshot it
    // after host mutations, rather than repeating that work on search/focus redraws.
    @State private var catalog: [ExtensionHost.Entry] = []
    @State private var catalogRefresh: Task<Void, Never>?
    @State private var presentation = Feel06PresentationCache<PresentationKey, Presentation>()
    private struct PresentationKey: Equatable {
        let items: [ExtensionManagerModel.Item]
        let query: String
        let filter: ExtensionManagerModel.Filter
    }
    private struct Presentation {
        let visible: [ExtensionManagerModel.Item]
        let counts: [ExtensionManagerModel.Filter: Int]
    }
    @State private var dropTargeted = false
    @State private var importError: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedFilter: ExtensionManagerModel.Filter?

    private var profileName: String {
        ProfileManager.shared.profiles.first { $0.id == host.profileID }?.name
            ?? (host.profileID == Profile.incognito.id ? "Private" : "Profile")
    }
    private var isPrivate: Bool { host.profileID == Profile.incognito.id }
    private var busy: Bool { importBusy || host.isBusy }
    private var items: [ExtensionManagerModel.Item] {
        catalog.map { entry in
            .init(id: entry.path, name: entry.name, version: entry.version, summary: entry.summary,
                  enabled: entry.enabled,
                  needsAttention: entry.failure != nil || !entry.sourceAvailable)
        }
    }
    private var prepared: Presentation {
        presentation.value(for: PresentationKey(items: items, query: query, filter: filter)) {
            let items = items
            let visible = ExtensionManagerModel.visible(items, query: query, filter: filter).sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return Presentation(visible: visible, counts: ExtensionManagerModel.counts(items))
        }
    }
    private var visible: [ExtensionManagerModel.Item] { prepared.visible }
    private var entries: [ExtensionHost.Entry] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.path, $0) })
        return visible.compactMap { byID[$0.id] }
    }
    private var selectedEntry: ExtensionHost.Entry? { entries.first { $0.path == selected } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                if isPrivate {
                    emptyState(icon: "eyeglasses", title: "Extensions stay out of private browsing",
                               detail: "Extensions cannot be installed in the Private profile. Open a regular profile to manage its extensions.")
                } else if catalog.isEmpty {
                    firstInstall
                } else {
                    content(wide: geometry.size.width >= 800)
                }
                if let importError {
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(importError).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { self.importError = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss installation error")
                    }.padding(14).background(.quaternary.opacity(0.4))
                    .accessibilityElement(children: .contain)
                }
            }
            .overlay {
                if dropTargeted && !isPrivate {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3)
                        .padding(6).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !isPrivate, !busy else { return false }
                guard urls.count == 1, let folder = urls.first, folder.isFileURL,
                      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    importError = "Drop one local extension folder containing manifest.json. Extract ZIP archives in Finder first."
                    return false
                }
                importFolder(folder)
                return true
            } isTargeted: { dropTargeted = $0 }
            .animation(Motion.reduced ? nil : Look.list, value: selected)
            .animation(Motion.reduced ? nil : Look.list, value: filter)
            .animation(Motion.reduced ? nil : Look.list, value: busy)
            .vaneMotionPolicy()
        }
        .onAppear { refreshCatalog() }
        .onDisappear { catalogRefresh?.cancel(); catalogRefresh = nil }
        .onReceive(host.objectWillChange) { _ in refreshCatalog() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCatalog()
        }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionManagement.presentationRequest)) { note in
            if note.object as? UUID == host.profileID { refreshCatalog() }
        }
        .onChange(of: visible.map(\.id)) { _, _ in
            selected = ExtensionManagerModel.selection(selected, in: visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: ExtensionManagement.searchRequest)) { note in
            if note.object as? UUID == host.profileID {
                selected = nil
                Task { await Task.yield(); searchFocused = true }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Extensions").font(.title2.weight(.semibold))
                Label(profileName, systemImage: isPrivate ? "eyeglasses" : "person.crop.circle")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Profile: \(profileName)")
                    .help("Extensions, permissions, and settings belong to this profile.")
            }
            Spacer(minLength: 8)
            Feel06ActivityLine(busy: busy, text: "Checking…")
                .frame(width: 100)
            Menu {
                Button("From Chrome Web Store…", systemImage: "globe") { host.chooseStoreInstall() }
                Button("From Folder or Safari App…", systemImage: "folder") { host.chooseAndInstall() }
            } label: { Label("Install Extension…", systemImage: "plus") }
                .disabled(isPrivate || busy)
                .accessibilityIdentifier("extension-manager.install")
                .help("Install from the Chrome Web Store, an unpacked folder, or a signed Safari extension app.")
        }.padding(.horizontal, 22).padding(.vertical, 18)
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        if wide {
            HStack(spacing: 0) {
                listPanel.frame(width: 320)
                Divider()
                if let entry = selectedEntry {
                    ExtensionDetailView(host: host, entry: entry)
                        .id(entry.path).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState(icon: "puzzlepiece.extension", title: "Make extensions your own",
                               detail: "Select an extension to see its access, settings, and troubleshooting tools.")
                }
            }
        } else if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                Button { Motion.list { selected = nil }; searchFocused = true } label: {
                    Label("All Extensions", systemImage: "chevron.left")
                }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 14)
                    .accessibilityLabel("Back to extension list")
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                ExtensionDetailView(host: host, entry: entry).id(entry.path)
            }.transition(.opacity)
        } else {
            listPanel.transition(.opacity)
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search extensions", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityLabel("Search extensions by name, description, or version")
                .accessibilityIdentifier("extension-manager.search")
                .padding(.horizontal, 14).padding(.top, 16)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(ExtensionManagerModel.Filter.allCases) { choice in
                    Button { Motion.list { filter = choice } } label: {
                        HStack(spacing: 5) {
                            Text(choice.rawValue).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(String(prepared.counts[choice] ?? 0))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption).padding(.horizontal, 9).padding(.vertical, 7)
                            .background(filter == choice ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).focused($focusedFilter, equals: choice)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(focusedFilter == choice ? Color.accentColor : Color.clear, lineWidth: 2)
                        }
                        .accessibilityLabel("\(choice.rawValue), \(prepared.counts[choice] ?? 0) extensions")
                        .accessibilityAddTraits(filter == choice ? [.isSelected] : [])
                }
            }.padding(14)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                    Text("No matching extensions").font(.headline)
                    Text("Try another search or filter.").font(.callout).foregroundStyle(.secondary)
                    Button("Clear Search & Filters") { query = ""; filter = .all; searchFocused = true }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(entries) { entry in
                        ExtensionListRow(host: host, entry: entry).tag(entry.path)
                            .padding(.vertical, 6)
                    }
                }.listStyle(.inset).accessibilityLabel("Installed extensions")
                    .accessibilityIdentifier("extension-manager.list")
            }
            Divider()
            Text("Drop an extension folder here to install.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var firstInstall: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text("A little more browser, your way").font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Install extensions from the Chrome Web Store, a local folder, or a Safari app. Each profile keeps its own extensions and access.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button("From Chrome Web Store…") { host.chooseStoreInstall() }
                .buttonStyle(.borderedProminent).disabled(busy)
            Button("Choose Folder or Safari App…") { host.chooseAndInstall() }.disabled(busy)
            Text("Or drop a folder containing manifest.json here.\nMV2 and MV3 support depends on the APIs available in WebKit and Vane.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshCatalog() {
        guard ExtensionManagement.isVisible(for: host.profileID) else { return }
        catalogRefresh?.cancel()
        catalogRefresh = Task { @MainActor in
            // objectWillChange arrives before the new host values. Coalesce a burst
            // and read after the mutation without doing work from a hover callback.
            await Task.yield()
            guard !Task.isCancelled, ExtensionManagement.isVisible(for: host.profileID) else { return }
            catalog = host.entries
            catalogRefresh = nil
        }
    }

    private func importFolder(_ folder: URL) {
        importBusy = true
        importError = nil
        Task {
            defer { importBusy = false }
            do { try await host.install(folder: folder) }
            catch is CancellationError { }
            catch { importError = error.localizedDescription }
        }
    }
}

private struct ExtensionIcon: View {
    let image: NSImage?
    var size: CGFloat = 38
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "puzzlepiece.extension.fill").resizable().scaledToFit()
                    .padding(size * 0.2).foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct ExtensionListRow: View {
    @ObservedObject var host: ExtensionHost
    let entry: ExtensionHost.Entry
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 11) {
                ExtensionIcon(image: entry.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.headline).lineLimit(2)
                    if !entry.version.isEmpty {
                        Text("Version " + entry.version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if entry.busy { ProgressView().controlSize(.small).accessibilityLabel("Checking " + entry.name) }
            }
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Label(entry.status, systemImage: entry.failure != nil ? "exclamationmark.circle" : entry.context != nil ? "checkmark.circle" : "pause.circle")
                    .font(.caption).foregroundStyle(entry.failure != nil ? Color.orange : Color.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Button { host.togglePin(entry.path) } label: {
                    Image(systemName: host.pins.contains(entry.path) ? "pin.fill" : "pin")
                        .frame(width: 20, height: 20)
                }.buttonStyle(.borderless)
                    .accessibilityLabel((host.pins.contains(entry.path) ? "Unpin " : "Pin ") + entry.name)
                    .help(host.pins.contains(entry.path) ? "Unpin from the toolbar" : host.canPin ? "Pin to the toolbar" : "Three extensions are already pinned. Unpin one first.")
                    .disabled(entry.busy || (!host.pins.contains(entry.path) && !host.canPin))
                Toggle("Enable " + entry.name, isOn: Binding(get: { entry.enabled }, set: { value in
                    Task {
                        do { try await host.setEnabled(value, for: entry.path) }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(entry.busy)
                    .accessibilityLabel("Enable " + entry.name)
            }
        }.contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .animation(Motion.reduced ? nil : Look.list, value: entry.enabled)
            .alert("Could not change extension", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}

private struct ExtensionDetailView: View {
    @ObservedObject var host: ExtensionHost
    let entry: ExtensionHost.Entry
    @State private var error: String?
    @State private var confirmingRemoval = false
    @State private var confirmingRevocation = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                identity
                if let failure = entry.failure {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text(failure).font(.callout).textSelection(.enabled)
                        HStack {
                            Button("Retry") { retry() }
                            Button("Choose Updated Folder…") { host.chooseUpdate(for: entry.path) }
                        }.controlSize(.small).disabled(entry.busy)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                actions
                source
                accessSection("Required installation access", access: entry.requiredAccess,
                              explanation: "Reviewed when installed or updated. Unavailable capabilities are not granted; see Compatibility. Disable or remove the extension to stop its access.")
                accessSection("Optional capabilities", access: entry.optionalAccess,
                              explanation: "Declared by the extension, but not automatically approved. It must request additional access when needed.")
                runtimeAccess
                if let context = entry.context { commands(context) }
                compatibility
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Button(copied ? "Diagnostics Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.diagnostic(for: entry), forType: .string)
                        copied = true
                    }
                    Spacer()
                    Button("Remove…", role: .destructive) { confirmingRemoval = true }
                        .disabled(entry.busy)
                }.controlSize(.small)
                Text("Copied diagnostics exclude website targets, personal paths, browsing content, credentials, and extension storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .accessibilityLabel(entry.name + " details")
        .alert("Could not change extension", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .alert("Remove “\(entry.name)” from this profile?", isPresented: $confirmingRemoval) {
            Button("Remove Extension", role: .destructive) {
                do { try host.remove(folder: entry.path) }
                catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the installation, its approval, and toolbar pin. Your original source folder is kept. Reinstalling creates a new extension identity and cannot restore its old settings.")
        }
        .alert("Revoke additional access?", isPresented: $confirmingRevocation) {
            Button("Revoke Additional Access", role: .destructive) {
                if let context = entry.context { host.revokeRuntimeAccess(context) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Clears optional/runtime grants, temporary active-page access, and denied requests. The extension may ask again. Required installation access stays approved, and past website changes cannot be undone.")
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 15) {
                ExtensionIcon(image: entry.icon, size: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text([entry.version.isEmpty ? nil : "Version " + entry.version, entry.status].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if entry.busy { ProgressView().controlSize(.small).accessibilityLabel("Checking extension") }
            }
            if !entry.summary.isEmpty { Text(entry.summary).font(.callout).textSelection(.enabled) }
            HStack(spacing: 15) {
                Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: { value in
                    Task {
                        do { try await host.setEnabled(value, for: entry.path) }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                })).toggleStyle(.switch).controlSize(.small).fixedSize()
                    .accessibilityLabel("Enable " + entry.name)
                Spacer(minLength: 0)
                Button(host.pins.contains(entry.path) ? "Unpin" : "Pin to Toolbar",
                       systemImage: host.pins.contains(entry.path) ? "pin.slash" : "pin") {
                    host.togglePin(entry.path)
                }.controlSize(.small)
                    .disabled(!host.pins.contains(entry.path) && !host.canPin)
                    .help("Up to three pins per profile. Disabled extensions retain their saved pin and hide from the toolbar.")
            }.disabled(entry.busy)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }.controlSize(.small).disabled(entry.busy)
    }

    @ViewBuilder private var actionButtons: some View {
        if let context = entry.context, context.optionsPageURL != nil {
            Button("Open Options…", systemImage: "slider.horizontal.3") {
                Task {
                    do { try await host.webExtensionController(host.controller, openOptionsPageFor: context) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        Button(entry.storeID != nil ? "Update from Store…" : entry.safariApp ? "Update from App…" : "Update from Folder…", systemImage: "arrow.clockwise") { host.chooseUpdate(for: entry.path) }
        if entry.context == nil && entry.failure == nil {
            Button("Retry", systemImage: "arrow.trianglehead.clockwise") { retry() }
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Installation source").font(.headline)
            Label(entry.storeID != nil ? "Chrome Web Store" : entry.safariApp ? "Signed Safari extension from app" : entry.managed ? "Managed local copy" : "Local folder", systemImage: entry.storeID != nil ? "globe" : entry.safariApp ? "app" : "folder")
                .font(.callout)
            Text(entry.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.sourceAvailable {
                Label(entry.safariApp ? "The source app is missing or unreadable. Reinstall the original app and choose Retry, or locate it with Update from App." : entry.managed ? "The source folder is missing or unreadable. Your accepted code is still available."
                      : "The folder moved, disappeared, or cannot be read. Choose its current location to recover this installation.",
                      systemImage: "exclamationmark.folder")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.storeID != nil ? "Vane verifies each store download’s signatures before unpacking it. Updates are checked daily while Vane is running. Added access requires review through Update from Store; the accepted version stays active until then." : entry.safariApp ? "Vane verifies the app and Safari extension’s signatures and runs an accepted copy. App updates are checked at restart or with Update from App and require review before activation. Native messaging to the app is unavailable." : entry.managed ? "Source-folder edits apply only through Update from Folder. Vane validates and reviews the new copy before activating it."
                 : "Vane will keep a validated managed copy when this installation is next loaded or updated. Its identity and existing settings are preserved.")
                .font(.caption).foregroundStyle(.secondary)
            if let id = entry.storeID, let store = try? ChromeWebStore(input: id) {
                Link("View in Chrome Web Store", destination: store.listingURL).controlSize(.small)
            } else {
                Button(entry.safariApp ? "Reveal Source App" : "Reveal Source Folder", systemImage: "folder") {
                    NSWorkspace.shared.selectFile(entry.sourcePath, inFileViewerRootedAtPath: URL(fileURLWithPath: entry.sourcePath).deletingLastPathComponent().path)
                }.controlSize(.small).disabled(!entry.sourceAvailable)
            }
        }
    }

    private func accessSection(_ title: String, access: ExtensionAccess?, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            if let access {
                if access.isEmpty {
                    Text("None declared").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(access.permissions.sorted(), id: \.self) { permission in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ExtensionAccess.phrase(permission)).font(.callout)
                            Text(permission).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !access.sites.isEmpty {
                        Text(title == "Required installation access" ? "Approved website access" : "Optional website access")
                            .font(.subheadline.weight(.medium)).padding(.top, 3)
                        ForEach(access.sites.sorted(), id: \.self) { site in
                            Text(site == "<all_urls>" || site == "*://*/*" ? "All websites (" + site + ")" : site)
                                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Text("Access metadata is unavailable. Retry or choose the source folder to validate its manifest.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var runtimeAccess: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Temporary & runtime access").font(.headline)
            Text("Additional grants are separate from installation approval. They expire at the time shown or when the extension reloads, is disabled, or Vane quits.")
                .font(.caption).foregroundStyle(.secondary)
            if let context = entry.context {
                let required = entry.requiredAccess ?? ExtensionAccess(permissions: [], sites: [])
                let permissions = context.grantedPermissions.filter { !required.permissions.contains($0.key.rawValue) && $0.value > .now }
                let sites = context.grantedPermissionMatchPatterns.filter { !required.sites.contains($0.key.string) && $0.value > .now }
                let usesActiveTab = required.permissions.contains("activeTab") || entry.optionalAccess?.permissions.contains("activeTab") == true
                if permissions.isEmpty && sites.isEmpty {
                    Text("No additional grants").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(permissions.keys.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { permission in
                    grantRow(ExtensionAccess.phrase(permission.rawValue), expiration: permissions[permission] ?? .distantFuture)
                }
                ForEach(sites.keys.sorted { $0.string < $1.string }, id: \.string) { pattern in
                    grantRow(pattern.string, expiration: sites[pattern] ?? .distantFuture)
                }
                if usesActiveTab {
                    Text("Using the extension may also give it temporary active-page access through activeTab. That access ends when you navigate away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Revoke Additional Access…") { confirmingRevocation = true }
                    .controlSize(.small)
                    .disabled(entry.busy || (!usesActiveTab && permissions.isEmpty && sites.isEmpty && context.deniedPermissions.isEmpty && context.deniedPermissionMatchPatterns.isEmpty))
            } else {
                Text("No active extension session").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func grantRow(_ name: String, expiration: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.callout).textSelection(.enabled)
            Text(expiration == .distantFuture ? "Until this extension session ends" : "Expires " + expiration.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func commands(_ context: WKWebExtensionContext) -> some View {
        let commands = ExtensionCommands.descriptors(for: context)
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Keyboard commands").font(.headline)
                ForEach(commands) { command in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(command.title).font(.callout)
                            Spacer(minLength: 10)
                            Text(command.shortcut.isEmpty ? "Not assigned" : command.shortcut)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let conflict = command.conflict {
                            Text(conflict).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Text("Browser shortcuts take precedence. Command/Control shortcuts also work in text fields; shortcuts that can insert text wait until you leave the field. Commands run only in this profile’s browser windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Compatibility").font(.headline)
            Text("Vane runs MV2/MV3 WebExtensions through macOS WebKit. Installing from the store does not guarantee compatibility; available APIs depend on both WebKit and Vane’s browser integration.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(entry.compatibility, id: \.self) { limitation in
                Label(limitation, systemImage: "info.circle").font(.callout)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func retry() {
        Task {
            do { try await host.retry(entry.path) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
