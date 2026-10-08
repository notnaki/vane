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
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ExtensionManagementView(host: host))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Extensions").font(.title2.weight(.semibold))
                Spacer()
                Button("Install Extension…") { host.chooseAndInstall() }
                    .disabled(host.profileID == Profile.incognito.id)
            }
            Text("Unpacked MV2/MV3 WebExtensions run through macOS WebKit. Compatibility depends on the extension’s APIs and Vane’s integration.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if host.entries.isEmpty {
                        Text("No extensions installed in this profile.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(host.entries) { entry in
                        row(entry)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Update from Folder checks the current files and reviews added access before enabling them. Failed updates stop the extension and keep its settings for a retry. Disabled extensions stay disabled after quitting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .animation(Motion.reduced ? nil : Look.list,
                   value: host.entries.map { $0.path + $0.status })
    }

    private func row(_ entry: ExtensionHost.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.name).font(.headline)
                Spacer()
                if entry.busy { ProgressView().controlSize(.small) }
                Text(entry.status).font(.callout).foregroundStyle(.secondary)
            }
            Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let failure = entry.failure {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
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
                Spacer()
                Button("Access & Diagnostics…") {
                    ExtensionManagement.showDetails(host.diagnostic(for: entry), title: entry.name)
                }
            }.controlSize(.small)
            if let context = entry.context {
                HStack(spacing: 10) {
                    if context.optionsPageURL != nil {
                        Button("Options…") {
                            Task {
                                do { try await host.webExtensionController(host.controller, openOptionsPageFor: context) }
                                catch { ExtensionManagement.showDetails(error.localizedDescription, title: "Could not open options") }
                            }
                        }
                    }
                    Button("Revoke Additional Access") { host.revokeRuntimeAccess(context) }
                        .help("Clears additional runtime grants and denials. Required manifest access remains approved; disable the extension to stop all access.")
                    Button("Show Folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.path) }
                }.controlSize(.small)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { ExtensionManagement.showDetails(error.localizedDescription, title: "Could not change extension") }
    }
}
