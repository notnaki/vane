import AppKit
import SwiftUI
import WebKit

struct WebsiteDataSheet: View {
    let profileName: String
    let isPrivate: Bool
    let onClose: (() -> Void)?
    @StateObject private var model: WebsiteDataModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    init(profileID: UUID, profileName: String, store: WKWebsiteDataStore? = nil,
         initialHost: String? = nil, isValid: (() -> Bool)? = nil, onClose: (() -> Void)? = nil) {
        let valid = isValid ?? { ProfileManager.shared.profiles.contains { $0.id == profileID } }
        self.init(model: WebsiteDataModel(profileID: profileID,
            store: store ?? (valid() ? ProfileManager.dataStore(for: profileID) : .nonPersistent()), isValid: valid, initialHost: initialHost),
            profileName: profileName, isPrivate: profileID == Profile.incognito.id, onClose: onClose)
    }

    init(model: WebsiteDataModel, profileName: String, isPrivate: Bool = false, onClose: (() -> Void)? = nil) {
        self.profileName = profileName
        self.isPrivate = isPrivate
        self.onClose = onClose
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Website Data").font(Look.heading)
            Text(isPrivate ? "Temporary data from this private tab. Saved profiles are not touched."
                 : "Stored by websites in “\(profileName)”. Other profiles are not touched.")
                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
            HStack {
                TextField("Search sites", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search stored website data")
                    .disabled(model.isBusy)
                Button("Refresh") { model.refresh() }.disabled(model.isBusy)
            }
            HStack(alignment: .top, spacing: 16) {
                siteList.frame(width: 235)
                details.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            Text("Disk usage unavailable: WebKit’s public API does not report per-site sizes. Site entries may include subdomains.")
                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
            if model.isBusy {
                HStack { ProgressView().controlSize(.small); Text(model.activity).font(Look.footnote) }
            }
            if let error = model.error { Text(error).font(Look.footnote).foregroundStyle(.red) }
            if let message = model.message { Text(message).font(Look.footnote).foregroundStyle(Look.inkSecondary) }
            HStack {
                if model.isBusy { Text("Operations continue if you close this view.").font(Look.footnote).foregroundStyle(Look.inkSecondary) }
                Spacer()
                Button("Done") { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("Clear Selected Data…", role: .destructive) { confirming = true }
                    .disabled(!model.canClear)
            }
        }
        .padding(Look.paneMargin)
        .frame(width: 720, height: 590)
        .font(Look.text)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if !model.hasLoaded { model.refresh() } }
        .onChange(of: model.error) { if let error = model.error { axAnnounce(error) } }
        .onChange(of: model.message) { if let message = model.message { axAnnounce(message) } }
        .alert("Clear selected data for “\(model.selectedName ?? "")”?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Data", role: .destructive) { model.clearSelection() }
        } message: {
            Text("This clears the selected categories for this site entry and its subdomains in “\(profileName)”. "
                 + WebsiteDataCategory.effects(model.selectedTypes)
                 + " Close this site’s tabs first to prevent pages from retaining or recreating data. History, bookmarks, saved passwords and Vane’s site settings are kept. This cannot be undone.")
        }
    }

    private var siteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.filteredEntries.count) \(model.filteredEntries.count == 1 ? "site" : "sites")").font(Look.caption).foregroundStyle(Look.inkSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if model.hasLoaded && model.filteredEntries.isEmpty {
                        Text(model.entries.isEmpty ? "No stored website data." : "No matching sites.")
                            .font(Look.footnote).foregroundStyle(Look.inkSecondary).padding(10)
                    }
                    ForEach(model.filteredEntries) { entry in
                        Button {
                            Motion.list { model.select(entry.name) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).lineLimit(2).foregroundStyle(.primary)
                                Text("\(entry.types.count) data categories · Usage unavailable")
                                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(model.selectedName == entry.name ? Look.accentSelected : .clear,
                                        in: .rect(cornerRadius: Look.chipRadius))
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityAddTraits(model.selectedName == entry.name ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let entry = model.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.name).font(Look.heading).textSelection(.enabled)
                    Text("Available stored data").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    HStack {
                        Button("Select All") { model.selectedTypes = entry.types }
                        Button("Select None") { model.selectedTypes = [] }
                    }.disabled(model.isBusy)
                    ForEach(entry.types.sorted { WebsiteDataCategory.title($0) < WebsiteDataCategory.title($1) }, id: \.self) { type in
                        Toggle(WebsiteDataCategory.title(type), isOn: Binding(
                            get: { model.selectedTypes.contains(type) },
                            set: { if $0 { model.selectedTypes.insert(type) } else { model.selectedTypes.remove(type) } }))
                            .disabled(model.isBusy)
                    }
                    Text(WebsiteDataCategory.effects(model.selectedTypes))
                        .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                    Text("Open pages can retain login state or recreate data. Close this site’s tabs before clearing, then reopen them when needed.")
                        .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a site to inspect its stored data and choose what to clear.")
                .font(Look.text).foregroundStyle(Look.inkSecondary).padding(.top, 30)
        }
    }
}

/// Site controls use the exact live store, especially for private tabs. A retained window
/// cannot resolve a different profile if the user switches or deletes the original one.
@MainActor final class WebsiteDataWindow: NSObject, NSWindowDelegate {
    private static let shared = WebsiteDataWindow()
    private var windows: [ObjectIdentifier: NSWindow] = [:]

    static func show(host: String, tab: Tab) {
        let store = tab.web.configuration.websiteDataStore
        let profileID = tab.profileID
        let profileName = tab.isPrivate ? "Private tab" : ProfileManager.shared.profiles.first { $0.id == profileID }?.name ?? "Profile"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Website Data — \(profileName)"
        window.isReleasedWhenClosed = false
        window.delegate = shared
        window.contentView = NSHostingView(rootView: WebsiteDataSheet(
            profileID: profileID, profileName: profileName, store: store, initialHost: host,
            isValid: { [weak tab] in
                if profileID == Profile.incognito.id {
                    return tab?.existingWeb?.configuration.websiteDataStore === store
                }
                return ProfileManager.shared.profiles.contains { $0.id == profileID }
            }, onClose: { [weak window] in window?.close() }))
        shared.windows[ObjectIdentifier(window)] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows[ObjectIdentifier(window)] = nil }
    }
}
