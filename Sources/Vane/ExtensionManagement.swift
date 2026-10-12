import AppKit
import SwiftUI

@MainActor enum ExtensionManagement {
    private static var windows: [UUID: NSWindow] = [:]

    static func show(for host: ExtensionHost = .shared) {
        if let window = windows[host.profileID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let profile = ProfileManager.shared.profiles.first { $0.id == host.profileID }?.name ?? "Profile"
        window.title = "Extensions — " + profile
        SecondaryWindowStyle.apply(to: window)
        window.isReleasedWhenClosed = false
        window.contentView = SecondaryWindowStyle.host(ExtensionManagementView(host: host),
            minimumSize: NSSize(width: 620, height: 400))
        window.center()
        windows[host.profileID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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

    var body: some View {
        VStack(alignment: .leading, spacing: Look.cardInset) {
            SecondaryWindowHeader(title: "Extensions",
                subtitle: "Add tools that make Vane your own.", icon: "puzzlepiece.extension")
            HStack {
                Text("\(host.entries.count) \(host.entries.count == 1 ? "extension" : "extensions")")
                    .font(Look.caption).monospacedDigit().foregroundStyle(Look.inkSecondary)
                Spacer()
                Button("Install Extension…") { host.chooseAndInstall() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(host.profileID == Profile.incognito.id)
            }
            Text("Unpacked MV2/MV3 WebExtensions run through macOS WebKit. Compatibility depends on the extension’s APIs and Vane’s integration.")
                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
            if host.entries.isEmpty {
                SecondaryWindowEmptyState(title: "Make room for your tools",
                    subtitle: "Install an unpacked extension folder to get started.", icon: "puzzlepiece.extension")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Look.cardInset) {
                        ForEach(host.entries) { entry in row(entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Hairline()
            Text("Update from Folder checks the current files and reviews added access before enabling them. Failed updates stop the extension and keep its settings for a retry. Disabled extensions stay disabled after quitting.")
                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
        }
        .padding(.horizontal, Look.paneMargin)
        .padding(.top, Look.cardInset)
        .padding(.bottom, Look.paneMargin)
        .font(Look.text).foregroundStyle(Look.inkPrimary)
        .background(Look.panelFill)
        .animation(Motion.reduced ? nil : Look.list,
                   value: host.entries.map { $0.path + $0.status })
        .vaneMotionPolicy()
    }

    private func row(_ entry: ExtensionHost.Entry) -> some View {
        VStack(alignment: .leading, spacing: Look.cardInset) {
            HStack {
                Image(systemName: "puzzlepiece.extension")
                    .font(Look.icon).foregroundStyle(Look.inkSecondary).accessibilityHidden(true)
                Text(entry.name).font(Look.heading).lineLimit(2)
                Spacer()
                if entry.busy { ProgressView().controlSize(.small) }
                Text(entry.status).font(Look.caption).foregroundStyle(Look.inkSecondary)
                    .padding(.horizontal, Look.inset).padding(.vertical, Look.captionGap)
                    .background(Look.controlFill, in: .capsule)
            }
            Text(entry.path).font(Look.footnote).foregroundStyle(Look.inkTertiary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let failure = entry.failure {
                Text(failure).font(Look.footnote).foregroundStyle(Look.warning).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                actions(entry, stacked: false)
                actions(entry, stacked: true)
            }
            .buttonStyle(.bordered).controlSize(.small)
            if let context = entry.context {
                VStack(alignment: .leading, spacing: Look.inset) {
                    if context.optionsPageURL != nil {
                        Button("Options…") {
                            Task {
                                do { try await host.webExtensionController(host.controller, openOptionsPageFor: context) }
                                catch { ExtensionManagement.showDetails(error.localizedDescription, title: "Could not open options") }
                            }
                        }
                    }
                    HStack {
                        Button("Revoke Additional Access") { host.revokeRuntimeAccess(context) }
                            .help("Clears additional runtime grants and denials. Required manifest access remains approved; disable the extension to stop all access.")
                        Button("Show Folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.path) }
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(Look.cardInset)
        .secondaryWindowCard()
    }

    private func actions(_ entry: ExtensionHost.Entry, stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Look.inset))
            : AnyLayout(HStackLayout(spacing: Look.inset))
        return layout {
            HStack(spacing: Look.inset) {
                Button(entry.context != nil ? "Update from Folder" : entry.failure != nil ? "Retry" : "Enable") {
                    Task {
                        do { _ = try await host.refresh(entry.path) }
                        catch is CancellationError { }
                        catch { /* The host keeps the actionable failure in this row. */ }
                    }
                }.disabled(entry.busy)
                if entry.context != nil {
                    Button("Disable") { perform { try host.disable(entry.path) } }
                }
                Button("Remove") { perform { try host.remove(folder: entry.path) } }
                Button(host.pins.contains(entry.path) ? "Unpin" : "Pin") { host.togglePin(entry.path) }
                    .disabled(!host.pins.contains(entry.path) && !host.canPin)
                    .help("Up to three saved pins. Disabled extensions keep their pin until you unpin or remove them.")
            }
            Button("Access & Diagnostics…") {
                ExtensionManagement.showDetails(host.diagnostic(for: entry), title: entry.name)
            }
        }
        .fixedSize(horizontal: !stacked, vertical: false)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { ExtensionManagement.showDetails(error.localizedDescription, title: "Could not change extension") }
    }
}
