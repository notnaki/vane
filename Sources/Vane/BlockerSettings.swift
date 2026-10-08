import AppKit
import SwiftUI

/// Filter sources are shared, but the site exceptions shown here belong to this profile.
struct BlockerSettingsSection: View {
    let profileID: UUID
    @ObservedObject private var subscriptions = FilterSubscriptions.shared
    @ObservedObject private var status = BlockerStatus.shared
    @State private var url = ""
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        SettingsSection("Content Blocking") {
            SettingsCard {
                SettingsRow("Rule status") {
                    Text(status.updating ? "Compiling…" : status.message)
                        .font(Look.caption).foregroundStyle(Look.inkSecondary)
                        .textSelection(.enabled)
                    Button("Retry Rules") { Blocker.refresh() }.disabled(status.updating)
                }
                if let report = status.report {
                    SettingsRow("Conversion") {
                        Button("View Unsupported Rules…") { Self.showReport(report, title: "Current filter conversion") }
                    }
                }
                SettingsRow("Local filter files") {
                    Button("Import from Disk…") { Blocker.chooseAndAddList() }
                }
                ForEach(UserDefaults.vane.stringArray(forKey: "blockerImportedLists") ?? [], id: \.self) { name in
                    SettingsRow((UserDefaults.vane.dictionary(forKey: "blockerImportedNames") as? [String: String])?[name] ?? "Imported list " + String(name.prefix(8))) {
                        Button("Inspect…") { inspect(name) }
                    }
                }
                Footnote("Disk imports are local snapshots and never update over the network. Existing file references are retained (\((UserDefaults.vane.array(forKey: "blockerLists") ?? []).count) legacy references). URL subscriptions below update daily while Vane is running, including after startup and wake.")
                SettingsRow("Subscribe by URL") {
                    TextField("https://example.com/filters.txt", text: $url)
                        .textFieldStyle(.roundedBorder)
                    Button(adding ? "Adding…" : "Add") { add() }
                        .disabled(adding || url.isEmpty)
                }
                SettingsRow("URL subscriptions") {
                    Button("Update Now") { Task { await subscriptions.updateDue(force: true) } }
                        .disabled(subscriptions.items.isEmpty || !subscriptions.updating.isEmpty)
                }
                if subscriptions.items.isEmpty { Footnote("No URL subscriptions. The built-in starter list works offline.") }
                ForEach(subscriptions.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.url.absoluteString).font(Look.caption).textSelection(.enabled)
                        Text(subscriptionStatus(item)).font(Look.caption).foregroundStyle(Look.inkSecondary)
                        if let report = item.report { Text(report.summary).font(Look.caption).foregroundStyle(Look.inkSecondary) }
                        HStack {
                            Button("Update") { Task { await subscriptions.update(item.id) } }
                            if let report = item.report {
                                Button("Unsupported Rules…") { Self.showReport(report, title: item.url.lastPathComponent) }
                            }
                            Button("Remove") { Task { await subscriptions.remove(item.id) } }
                        }
                        .disabled(subscriptions.updating.contains(item.id))
                    }
                    .padding(.horizontal, Look.cardInset)
                    .padding(.vertical, 9)
                }
                if let storageError = subscriptions.storageError { Footnote(storageError) }
                if let error { Footnote(error) }
                Footnote("Failed downloads, conversion, compilation, or saves retain the previous working rules. Unsupported rules are skipped and reported by reason; Vane supports a subset of EasyList syntax.")
            }
            SettingsCard {
                SettingsRow("Site exceptions") { Text("This profile").font(Look.caption).foregroundStyle(Look.inkSecondary) }
                if Blocker.siteExceptions(for: profileID).isEmpty { Footnote("No site exceptions. Use Site Controls to turn blocking off for a site and reload it.") }
                ForEach(Blocker.siteExceptions(for: profileID), id: \.self) { host in
                    SettingsRow(host) {
                        Button("Resume Blocking") { Blocker.setSiteException(host, allowed: false, profileID: profileID) }
                    }
                }
                Footnote("Exceptions apply to the exact host, including its embedded content. Subdomains have their own setting. Subscription updates preserve these choices. Reload other open pages after changing an exception here.")
            }
        }
        .animation(Motion.reduced ? nil : Look.quick, value: subscriptions.items)
        .animation(Motion.reduced ? nil : Look.quick, value: status.revision)
    }

    private func subscriptionStatus(_ item: FilterSubscription) -> String {
        if subscriptions.updating.contains(item.id) { return "Updating…" }
        if let failure = item.lastError {
            let protection = item.text.isEmpty ? "No rules installed from this subscription." : "Previous rules retained."
            let attempt = item.lastAttempt.map { " (" + $0.formatted(date: .abbreviated, time: .shortened) + ")" } ?? ""
            return "Update failed\(attempt). \(protection) \(failure)"
        }
        guard let success = item.lastSuccess else { return "Waiting for first successful update." }
        return "Last checked: \(success.formatted(date: .abbreviated, time: .shortened)) · Next check: \(success.addingTimeInterval(86400).formatted(date: .abbreviated, time: .shortened))"
    }

    private func inspect(_ name: String) {
        Task {
            do {
                guard name == URL(fileURLWithPath: name).lastPathComponent else { return }
                let report = try await Task.detached(priority: .utility) {
                    Blocker.convert(try String(contentsOf: Blocker.importedDirectory.appendingPathComponent(name), encoding: .utf8)).report
                }.value
                Self.showReport(report, title: "Local filter file")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func add() {
        guard let candidate = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Enter an HTTPS filter-list URL."; return
        }
        adding = true; error = nil
        Task {
            defer { adding = false }
            do { try await subscriptions.add(candidate); url = "" }
            catch { self.error = error.localizedDescription }
        }
    }

    static func showReport(_ report: BlockerReport, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        // A selectable scrolling report keeps real lists with many reasons readable.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = report.details
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
}
