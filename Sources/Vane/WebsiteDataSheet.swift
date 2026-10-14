import AppKit
import SwiftUI
import WebKit

struct WebsiteDataSheet: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let profileName: String
    let isPrivate: Bool
    let onClose: (() -> Void)?
    @StateObject private var model: WebsiteDataModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @FocusState private var searchFocused: Bool

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
        VStack(alignment: .leading, spacing: Look.cardInset) {
            SecondaryWindowHeader(title: "Website Data", subtitle: isPrivate
                ? "Temporary data from this private tab. Saved profiles are not touched."
                : "Stored by websites in “\(profileName)”. Other profiles are not touched.",
                icon: "externaldrive")
            HStack(spacing: Look.cardInset) {
                HStack(spacing: Look.inset) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Look.inkSecondary)
                    TextField("Search sites", text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search stored website data")
                        .disabled(model.isBusy)
                }
                .secondaryWindowSearchField()
                Button("Refresh") { model.refresh() }.disabled(model.isBusy)
                    .buttonStyle(.bordered).controlSize(.large)
            }
            HStack(alignment: .top, spacing: Look.cardInset) {
                siteList.frame(width: 235)
                details
                    .padding(Look.cardInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .secondaryWindowCard()
            }
            .frame(maxHeight: .infinity)
            Hairline()
            Text("Disk usage unavailable: WebKit’s public API does not report per-site sizes. Site entries may include subdomains.")
                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
            Feel06ActivityLine(busy: model.isBusy, text: model.activity)
            if let error = model.error { Text(error).font(Look.footnote).foregroundStyle(.red) }
            if let message = model.message { Text(message).font(Look.footnote).foregroundStyle(Look.inkSecondary) }
            HStack {
                Text("Operations continue if you close this view.").font(Look.footnote).foregroundStyle(Look.inkSecondary)
                    .opacity(model.isBusy ? 1 : 0).accessibilityHidden(!model.isBusy)
                Spacer()
                Button("Done") { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("Clear Selected Data…", role: .destructive) { confirming = true }
                    .disabled(!model.canClear)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .padding(Look.paneMargin)
        .frame(width: 760, height: 640)
        .font(Look.text)
        .foregroundStyle(Look.inkPrimary)
        .background(Look.panelFill)
        .animation(Motion.reduced ? nil : Look.quick, value: model.selectedName)
        .animation(Motion.reduced ? nil : Look.quick, value: model.isBusy)
        .vaneMotionPolicy()
        .onAppear { if !model.hasLoaded { model.refresh() } }
        .onChange(of: model.isBusy) {
            if !model.isBusy && model.selectedName == nil { searchFocused = true }
        }
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
        let entries = model.filteredEntries
        return VStack(alignment: .leading, spacing: Look.inset) {
            Text("\(entries.count) \(entries.count == 1 ? "site" : "sites")").font(Look.caption).foregroundStyle(Look.inkSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.rowGap) {
                    if model.hasLoaded && entries.isEmpty {
                        Text(model.entries.isEmpty ? "No stored website data." : "No matching sites.")
                            .font(Look.footnote).foregroundStyle(Look.inkSecondary).padding(Look.rowInset)
                    }
                    ForEach(entries) { entry in
                        Button {
                            Motion.list { model.select(entry.name) }
                        } label: {
                            VStack(alignment: .leading, spacing: Look.rowGap) {
                                Text(entry.name).lineLimit(2).foregroundStyle(Look.inkPrimary)
                                Text("\(entry.types.count) data categories · Usage unavailable")
                                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Look.rowInset)
                            .background(model.selectedName == entry.name ? chromeTheme.accentSelected : .clear,
                                        in: .rect(cornerRadius: Look.chipRadius))
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityAddTraits(model.selectedName == entry.name ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(Look.inset)
        .frame(maxHeight: .infinity)
        .secondaryWindowCard()
    }

    @ViewBuilder private var details: some View {
        if let entry = model.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: Look.cardInset) {
                    Text(entry.name).font(Look.heading).textSelection(.enabled)
                    Text("Available stored data").font(Look.caption).foregroundStyle(Look.inkSecondary)
                    HStack {
                        Button("Select All") { model.selectedTypes = entry.types }
                        Button("Select None") { model.selectedTypes = [] }
                    }.buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy)
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
            SecondaryWindowEmptyState(title: "Choose a site",
                subtitle: "Inspect its stored data and choose what to clear.", icon: "externaldrive")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Website Data — \(profileName)"
        SecondaryWindowStyle.apply(to: window)
        window.isReleasedWhenClosed = false
        window.delegate = shared
        window.contentView = SecondaryWindowStyle.host(WebsiteDataSheet(
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
