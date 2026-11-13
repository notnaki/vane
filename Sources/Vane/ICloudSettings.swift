import SwiftUI

/// Sync choices belong to this Mac. Opening the pane never enables sync or uploads data.
struct ICloudSettings: View {
    @ObservedObject var controller: ICloudController
    @State private var review: Review?
    @State private var comparing: ICloudSecrets.Conflict?

    private enum Review: String, Identifiable {
        case enable, selectAll, account, remove
        var id: String { rawValue }
    }

    private let groups: [(String, [ICloudCategory])] = [
        ("Your library", [.profiles, .spaces, .favourites, .pinnedTabs, .sidebarFolders, .bookmarks]),
        ("Browsing", [.openTabs, .recentlyClosedTabs, .history, .downloadHistory]),
        ("Saved work", [.easels, .readingQueue, .offlineArticles, .spaceTemplates, .boosts]),
        ("Preferences", [.appearance, .readerPreferences, .search, .keyboardShortcuts,
                          .portablePreferences, .siteSettings, .contentBlocking]),
        ("Extensions", [.extensions, .extensionSyncData]),
        ("iCloud Keychain", [.passwords, .aiKeys]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            SettingsCard {
                SettingsRow("Sync Vane with iCloud", icon: "icloud.fill", tint: .blue) {
                    Toggle("Sync Vane with iCloud", isOn: Binding(
                        get: { controller.masterEnabled },
                        set: { enabled in
                            if enabled { present(.enable) }
                            else { Task { await controller.setMasterEnabled(false) } }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!controller.masterEnabled && (controller.busy || !controller.canEnable))
                }
                Footnote("Uses this Mac’s Apple Account. Review the categories below before enabling. Your first sync saves a local recovery point and merges your saved library with iCloud.")
                SettingsRow(controller.status, icon: "arrow.triangle.2.circlepath", tint: .blue) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    Button("Sync Now") { Task { await controller.syncNow() } }
                        .disabled(controller.busy || !controller.masterEnabled || controller.needsAccountConsent)
                }
                if let date = controller.lastSuccess {
                    Footnote("Last successful sync: \(date.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    Footnote("No successful sync yet.")
                }
                if let error = controller.lastError {
                    Text(error).font(Look.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Look.cardInset)
                        .textSelection(.enabled)
                }
                if controller.needsAccountConsent {
                    SettingsRow("Your Apple Account changed", icon: "person.crop.circle.badge.exclamationmark", tint: .orange) {
                        Button("Review Merge…") { present(.account) }.disabled(controller.busy)
                    }
                    Footnote("Sync is paused. Your local library is preserved. Review your choices before merging it with the current Apple Account.")
                }
                if controller.pendingRemoval {
                    SettingsRow("Previous iCloud removal is unfinished", icon: "exclamationmark.arrow.triangle.2.circlepath", tint: .orange) {
                        Button("Finish Removal") { Task { await controller.resumeCloudRemoval() } }
                            .disabled(controller.busy || !controller.canEnable)
                    }
                    Footnote("The confirmed request and old cloud namespaces are kept until deletion succeeds. Use the original Apple Account and a provisioned build to retry. Sync stays off; your local copies remain.")
                }
            }

            SettingsDisclosure("Categories on this Mac", summary: "Library, browsing, saved work, and preferences",
                               icon: "square.grid.2x2.fill", tint: .purple) {
                VStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    SettingsCard {
                        SettingsRow("Categories on this Mac", icon: "checklist", tint: .purple) {
                            Button("Select All…") { present(.selectAll) }.disabled(controller.busy)
                        }
                        Footnote(controller.masterEnabled
                                 ? "Each switch controls both sending and receiving on this Mac. Turning one off keeps existing local and iCloud copies."
                                 : "Choose what this Mac sends and receives. Nothing is uploaded until you enable iCloud and accept the review.")
                    }

                    ForEach(groups, id: \.0) { title, categories in
                        SettingsSection(title) {
                            SettingsCard {
                                ForEach(categories, id: \.rawValue) { category in
                                    categoryRow(category)
                                }
                                if title == "iCloud Keychain" {
                                    Footnote("Passwords and AI keys use iCloud Keychain separately from your library. Turning these switches off stops Vane’s cloud reads and writes; it cannot stop Apple’s background transport for items already in iCloud Keychain. Removing cloud items is a separate action below.")
                                }
                            }
                        }
                    }
                }
            }

            if !controller.secretConflicts.isEmpty {
                SettingsSection("Credential conflicts") {
                    ForEach(controller.secretConflicts) { conflict in
                        SettingsCard {
                            SettingsRow(conflict.identity.origin ?? "AI provider key", icon: "key.fill", tint: .orange) {
                                Button("Keep This Mac’s Copy") {
                                    Task { await controller.resolveSecretConflict(conflict, choosing: .keepThisMac) }
                                }
                                .disabled(controller.busy || !controller.masterEnabled || !controller.enabledCategories.contains(conflict.category))
                            }
                            Footnote(conflict.identity.account.isEmpty ? "Account without a username" : conflict.identity.account)
                            SettingsRow("Use a reviewed iCloud version", icon: "icloud.fill", tint: .blue) {
                                Button("Review iCloud Versions…") { Motion.animate(Look.quick) { comparing = conflict } }
                                .disabled(controller.busy || !controller.masterEnabled || !controller.enabledCategories.contains(conflict.category))
                            }
                            Footnote("Only the versions shown here are resolved. New changes from another Mac remain for review. A deletion removes this Mac’s saved credential; other choices keep or replace its saved value. Edit a local credential in its normal settings first, then review the refreshed conflict to keep that edited copy.")
                        }
                    }
                }
            }

            SettingsDisclosure("Other Macs", summary: "Tabs and completed-download history",
                               icon: "desktopcomputer", tint: .blue) {
                if let library = controller.library {
                    ICloudOtherMacs(library: library, enabled: controller.enabledCategories)
                } else {
                    SettingsCard { Footnote("Tabs and completed-download history from your other Macs appear here after syncing.") }
                }
            }

            SettingsDisclosure("What stays on this Mac", summary: "Private data, sign-ins, and local files",
                               icon: "lock.shield.fill", tint: .green) {
                SettingsCard {
                    Footnote("Private browsing, cookies, website sign-ins, website storage, passkeys, unsaved forms, active media, downloaded files, and in-progress downloads stay local. You may need to sign in to websites again on another Mac.")
                    Footnote("GitHub Live Folder definitions can sync, but GitHub authentication stays on each Mac: sign in again there. macOS permissions, extension grants, local paths, file access grants, biometric unlock, and certificate exceptions also stay local. Extension storage outside its sync namespace stays with the extension on each Mac.")
                    Footnote("Synced Boost scripts arrive disabled. Extensions need verification and this Mac’s consent before activation; Safari extensions need their host app installed here.")
                    Footnote("Saved assets are limited to 32 MB each, with up to 256 MB per sync cycle. iCloud storage or transfer failures appear above; your local data and pending changes are kept.")
                }
            }

            SettingsDisclosure("Remove cloud copies", summary: "Choose iCloud data to remove; keep local copies",
                               icon: "trash.fill", tint: .red) {
                SettingsCard {
                    SettingsRow("Remove selected iCloud data", icon: "trash.fill", tint: .red) {
                        Button("Remove iCloud Data…") { present(.remove) }.disabled(controller.busy)
                    }
                    Footnote("Choose categories and confirm first. This pauses all sync on this Mac and keeps local copies. Other Macs pause the removed library categories until you deliberately enable them again. iCloud Keychain items have a separate removal section.")
                }
            }
        }
        .padding(.top, Look.inset * 2)
        .vaneMotionPolicy()
        .sheet(item: $review) { item in
            if item == .remove {
                ICloudRemovalReview(controller: controller)
            } else {
                consentReview(item)
            }
        }
        .sheet(item: $comparing) { conflict in
            if let bridge = controller.credentialReviewBridge {
                ICloudCredentialComparison(conflict: conflict, bridge: bridge,
                    admission: controller.credentialReviewAdmission(for: conflict),
                    choose: { conflict, choice in await controller.resolveSecretConflict(conflict, choosing: choice) })
            }
        }
    }

    private func present(_ item: Review) { Motion.animate(Look.quick) { review = item } }

    @ViewBuilder private func categoryRow(_ category: ICloudCategory) -> some View {
        let style = Self.style(category)
        SettingsRow(category.title, icon: style.icon, tint: style.tint) {
            Toggle(category.title, isOn: Binding(
                get: { controller.enabledCategories.contains(category) },
                set: { enabled in
                    Motion.animate(Look.quick) { controller.setEnabled(enabled, for: category) }
                }
            )).labelsHidden()
        }
        if let detail = Self.detail(category) { Footnote(detail) }
    }

    private static func style(_ category: ICloudCategory) -> (icon: String, tint: Color) {
        switch category {
        case .profiles: ("person.fill", .purple)
        case .spaces: ("square.grid.2x2.fill", .purple)
        case .favourites: ("star.fill", .purple)
        case .pinnedTabs: ("pin.fill", .purple)
        case .sidebarFolders: ("folder.fill", .purple)
        case .bookmarks: ("bookmark.fill", .purple)
        case .openTabs: ("macwindow", .blue)
        case .recentlyClosedTabs: ("arrow.uturn.backward", .blue)
        case .history: ("clock.fill", .blue)
        case .downloadHistory: ("arrow.down.circle.fill", .blue)
        case .easels: ("rectangle.on.rectangle", .green)
        case .readingQueue: ("text.book.closed.fill", .green)
        case .offlineArticles: ("doc.text.fill", .green)
        case .spaceTemplates: ("square.on.square", .green)
        case .boosts: ("paintbrush.fill", .green)
        case .appearance: ("paintpalette.fill", .blue)
        case .readerPreferences: ("book.fill", .blue)
        case .search: ("magnifyingglass", .blue)
        case .keyboardShortcuts: ("keyboard", .blue)
        case .portablePreferences: ("slider.horizontal.3", .blue)
        case .siteSettings: ("globe", .blue)
        case .contentBlocking: ("hand.raised.fill", .blue)
        case .extensions: ("puzzlepiece.extension.fill", .purple)
        case .extensionSyncData: ("externaldrive.fill", .purple)
        case .passwords: ("key.fill", .green)
        case .aiKeys: ("sparkles", .green)
        }
    }

    private static func detail(_ category: ICloudCategory) -> String? {
        switch category {
        case .history: "Includes existing browsing history. Clearing browsing history also removes synced history while this switch is on."
        case .downloadHistory: "Completed-download details only: source URL, filename, size, date, and owning Mac. Downloaded files and local file access never transfer."
        case .offlineArticles: "Saved article text and images. Reading queue links and read state have their own switch."
        case .extensionSyncData: "Only values an extension places in storage.sync transfer. Extensions may put sensitive data there; Vane cannot identify its meaning. Local and session storage do not transfer. Imported data waits for this Mac’s approved activation. Writes already submitted to WebKit may finish after you turn sync off."
        case .passwords: "Vane-owned saved website logins. Website sign-in sessions and passkeys are separate and stay local."
        case .aiKeys: "Registered API connection keys only. Matching connection definitions and API feature routes use Portable preferences. ChatGPT registrations, tokens and routes stay on this Mac. Only enable this if you want API keys in iCloud Keychain."
        default: nil
        }
    }

    private func consentReview(_ item: Review) -> some View {
        let categories = item == .selectAll
            ? Set(ICloudCategory.allCases)
            : controller.enabledCategories
        return VStack(alignment: .leading, spacing: 16) {
            Text(item == .selectAll ? "Select all available categories?" : item == .account
                 ? "Merge with this Apple Account?" : "Enable iCloud on this Mac?")
                .font(.title2.weight(.semibold))
            Text(item == .selectAll
                 ? "This includes browsing history, passwords, AI API keys, and extension sync data. Extensions can put sensitive values in their sync storage."
                 : "Vane will save a local recovery point, then merge the selected local data with this Apple Account’s iCloud data. Your existing library is kept.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ICloudCategory.allCases.filter { categories.contains($0) }, id: \.rawValue) { category in
                        Text(category.title + (category.isSecret ? " · iCloud Keychain" : ""))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            Text("Downloaded files never sync. Password and API key switches cannot stop Apple’s transport for existing iCloud Keychain items.")
                .font(Look.footnote).foregroundStyle(.secondary)
            if item == .selectAll {
                Text(controller.masterEnabled
                     ? "Sync is on. These categories can begin syncing after you confirm."
                     : "This changes your selection only. Enable iCloud separately to start syncing.")
                    .font(Look.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { review = nil }.keyboardShortcut(.cancelAction)
                Button(item == .selectAll ? "Select All" : item == .account ? "Merge with Current Account" : "Enable and Merge") {
                    review = nil
                    switch item {
                    case .selectAll: controller.selectAll()
                    case .enable: Task { await controller.setMasterEnabled(true) }
                    case .account: Task { await controller.mergeWithCurrentAccount() }
                    case .remove: break
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.busy || categories.isEmpty || (item == .enable && !controller.canEnable))
            }
        }
        .padding(24).frame(width: 480).vaneMotionPolicy()
    }
}

private struct ICloudRemovalReview: View {
    @ObservedObject var controller: ICloudController
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<ICloudCategory>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove iCloud data?").font(.title2.weight(.semibold))
            Text("Select the cloud copies to remove. All sync on this Mac pauses first. Local copies remain. Other Macs pause affected library categories and need deliberate re-enablement.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    removalGroup("Library and preferences", categories: ICloudCategory.allCases.filter { !$0.isSecret })
                    removalGroup("iCloud Keychain", categories: ICloudCategory.allCases.filter(\.isSecret))
                    Text("Selected Keychain items are removed through Apple’s Keychain service separately from the library reset. This removes Vane-owned cloud credentials; local snapshots remain. Apple controls propagation to your other devices.")
                        .font(Look.footnote).foregroundStyle(.secondary)
                }
            }.frame(height: 300)
            Text("Selected: \(selected.count) categories").font(Look.footnote)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove Selected Cloud Data", role: .destructive) {
                    let confirmed = selected
                    dismiss()
                    Task { await controller.removeCloudData(confirmed) }
                }.disabled(selected.isEmpty || controller.busy)
            }
        }.padding(24).frame(width: 500).vaneMotionPolicy()
    }

    private func removalGroup(_ title: String, categories: [ICloudCategory]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(categories, id: \.rawValue) { category in
                Toggle(category.title, isOn: Binding(
                    get: { selected.contains(category) },
                    set: { enabled in
                        Motion.animate(Look.quick) {
                            if enabled { _ = selected.insert(category) } else { _ = selected.remove(category) }
                        }
                    }
                )).toggleStyle(.checkbox)
            }
        }
    }
}

private struct ICloudOtherMacs: View {
    @ObservedObject var library: ICloudLibraryAdapter
    let enabled: Set<ICloudCategory>

    private var openTabs: [ICloudRemoteTab] { enabled.contains(.openTabs) ? library.remoteTabs : [] }
    private var closedTabs: [ICloudRemoteTab] { enabled.contains(.recentlyClosedTabs) ? library.remoteRecentlyClosedTabs : [] }
    private var downloads: [ICloudRemoteDownload] { enabled.contains(.downloadHistory) ? library.remoteDownloads : [] }
    private var deviceIDs: [String] {
        Set(openTabs.map(\.deviceID) + closedTabs.map(\.deviceID) + downloads.map(\.deviceID)).sorted()
    }

    var body: some View {
        SettingsCard {
            if deviceIDs.isEmpty {
                Footnote("No synced tabs or completed-download history from other Macs yet. Enable their categories and sync Vane on both Macs to see them here.")
            }
            ForEach(deviceIDs, id: \.self) { device in
                DisclosureGroup(deviceName(device)) {
                    tabList("Open tabs", rows: openTabs.filter { $0.deviceID == device })
                    tabList("Recently closed tabs", rows: closedTabs.filter { $0.deviceID == device })
                    let rows = downloads.filter { $0.deviceID == device }
                    if !rows.isEmpty {
                        Text("Download history").font(.headline).padding(.top, 8)
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).font(Look.text)
                                Text("\(row.deviceName) · \(row.completed.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))")
                                if let source = row.source { Text(source.absoluteString).textSelection(.enabled) }
                                Text("History only · File stays on \(row.deviceName)")
                            }
                            .font(Look.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }
                .padding(Look.cardInset)
            }
            Footnote("Open creates new local tabs in the matching profile and Space. Pages from another Mac never replace your current tabs. Download-history rows do not provide access to files on another Mac.")
        }
    }

    private func deviceName(_ id: String) -> String {
        openTabs.first { $0.deviceID == id }?.deviceName
            ?? closedTabs.first { $0.deviceID == id }?.deviceName
            ?? downloads.first { $0.deviceID == id }?.deviceName ?? "Mac"
    }

    @ViewBuilder private func tabList(_ title: String, rows: [ICloudRemoteTab]) -> some View {
        if !rows.isEmpty {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Open All") { open(rows) }.disabled(!rows.contains(where: canOpen))
                    .accessibilityLabel("Open all \(title.lowercased()) from \(rows.first?.deviceName ?? "Mac")")
            }.padding(.vertical, 8)
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title.isEmpty ? row.url.host ?? "Page" : row.title).font(Look.text)
                        Text(context(row)).font(Look.footnote).foregroundStyle(.secondary)
                        Text(row.url.absoluteString).font(Look.footnote).foregroundStyle(.secondary)
                            .lineLimit(2).help(row.url.absoluteString)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open") { open([row]) }.disabled(!canOpen(row))
                        .accessibilityLabel("Open \(row.title.isEmpty ? row.url.absoluteString : row.title)")
                }.padding(.vertical, 6)
            }
        }
    }

    private func context(_ row: ICloudRemoteTab) -> String {
        guard let profile = ProfileManager.shared.profiles.first(where: { $0.id == row.profileID }) else {
            return "Profile unavailable on this Mac"
        }
        let space = ProfileManager.shared.spaces(for: profile.id).first { $0.id == row.spaceID }
        if row.spaceID != nil && space == nil { return "\(profile.name) · Space unavailable on this Mac" }
        return [profile.name, space?.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func canOpen(_ row: ICloudRemoteTab) -> Bool {
        ["http", "https"].contains(row.url.scheme?.lowercased() ?? "")
            && row.url.host != nil && row.profileID != Profile.incognito.id
            && ProfileManager.shared.profiles.contains { $0.id == row.profileID }
            && (row.spaceID == nil || ProfileManager.shared.spaces(for: row.profileID).contains { $0.id == row.spaceID })
    }

    private func open(_ requested: [ICloudRemoteTab]) {
        // A fresh regular host preserves all existing navigation and never targets a
        // private, Little Vane, parked, or profile-mismatched store.
        let rows = requested.filter(canOpen)
        let groups = Dictionary(grouping: rows) { "\($0.profileID)|\($0.spaceID?.uuidString ?? "")" }
        for key in groups.keys.sorted() {
            guard let pages = groups[key], let first = pages.first,
                  let profile = ProfileManager.shared.profiles.first(where: { $0.id == first.profileID }) else { continue }
            let space = ProfileManager.shared.spaces(for: profile.id).first { $0.id == first.spaceID }
            Windows.open(urls: pages.map(\.url), profile: profile, space: space)
        }
    }
}
