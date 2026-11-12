import AppKit
import SwiftUI

/// Plaintext stays in this sheet's short-lived state. The parent receives only an opaque
/// review and resolution choice; there is deliberately no secret clipboard action.
@MainActor struct ICloudCredentialComparison: View {
    let conflict: ICloudSecrets.Conflict
    let bridge: ICloudSecrets
    let admission: @MainActor () -> Bool
    let choose: @MainActor (ICloudSecrets.Conflict, ICloudSecrets.Resolution) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inspections: [UUID: ICloudSecrets.Inspection] = [:]
    @State private var revealed: Set<UUID> = []
    @State private var reviewed: Set<UUID> = []
    @State private var expiry: [UUID: Task<Void, Never>] = [:]
    @State private var authentication: Task<Void, Never>?
    @State private var pending: UUID?
    @State private var context = UUID()
    @State private var active = false
    @State private var choosing = false
    @State private var problem: String?
    @State private var closing: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            Text("Review iCloud Versions").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.identity.origin ?? "AI provider key").font(Look.text.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(conflict.identity.account.isEmpty ? "No username" : conflict.identity.account)
                    .font(Look.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Authenticate to compare versions, then reveal the saved value you want to use. Values clear after 30 seconds, when this review closes, or when Vane leaves the foreground.")
                .font(Look.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    ForEach(conflict.reviewedHeads) { version in
                        versionRow(version)
                        if version.id != conflict.reviewedHeads.last?.id { Divider() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 180, maxHeight: 380)

            if let problem {
                Text(problem).font(Look.footnote).foregroundStyle(Look.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Nothing is copied to the clipboard.").font(Look.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { clear(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Look.cardInset)
        .frame(width: 560)
        .onAppear {
            active = NSApp.isActive
            closing = SettingsWindow.onClose { clear() }
        }
        .onDisappear {
            active = false
            clear()
            if let closing { NotificationCenter.default.removeObserver(closing) }
            closing = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            active = false
            clear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onChange(of: admission()) { _, allowed in
            if !allowed { clear(); problem = "Sync changed. Close this review and sync again before comparing credentials." }
        }
    }

    private func versionRow(_ version: ICloudSecrets.CloudVersion) -> some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            HStack {
                Text(version.isDeletion ? "Deleted version" : versionTitle(version)).font(Look.text.weight(.medium))
                Spacer()
                if pending == version.id { ProgressView().controlSize(.small).accessibilityLabel("Authenticating") }
            }
            if version.isDeletion {
                Text("This version removes the saved credential. Choosing it removes this Mac’s copy and resolves the versions in this review.")
                    .font(Look.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                credentialValue(version)
            }
            HStack(spacing: Look.inset) {
                if inspections[version.id] == nil {
                    Button(version.isDeletion ? "Authenticate to Review Deletion" : "Authenticate to Compare") { inspect(version) }
                        .disabled(pending != nil || choosing || !active || !admission())
                } else if !version.isDeletion {
                    Button(revealed.contains(version.id) ? "Hide" : "Reveal") {
                        if revealed.contains(version.id) { forget(version.id) }
                        else { Motion.instant { revealed.insert(version.id); reviewed.insert(version.id) } }
                    }.disabled(choosing || !admission())
                }
                Spacer()
                Button(version.isDeletion ? "Use Deletion" : "Use This Version", role: version.isDeletion ? .destructive : nil) {
                    select(version)
                }.disabled(!reviewed.contains(version.id) || pending != nil || choosing || !active || !admission())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func credentialValue(_ version: ICloudSecrets.CloudVersion) -> some View {
        if case .credential(let value, let matches)? = inspections[version.id] {
            Text(matches ? "Matches this Mac’s current credential" : "Different from this Mac’s current credential")
                .font(Look.footnote).foregroundStyle(.secondary)
            if revealed.contains(version.id) {
                ScrollView([.horizontal, .vertical]) {
                    Text(value.isEmpty ? "Empty credential" : value).font(.system(.body, design: .monospaced))
                        .textSelection(.disabled).privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 28, maxHeight: 100)
            } else {
                Text("••••••••").font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Credential hidden. Reveal it before choosing this version.")
            }
        } else {
            Text("••••••••").font(.system(.body, design: .monospaced)).accessibilityLabel("Credential hidden")
        }
    }

    private func versionTitle(_ version: ICloudSecrets.CloudVersion) -> String {
        let ordinal = (conflict.reviewedHeads.firstIndex(where: { $0.id == version.id }) ?? 0) + 1
        return "Saved version \(ordinal)"
    }

    private func inspect(_ version: ICloudSecrets.CloudVersion) {
        guard active, admission(), pending == nil else { return }
        let request = context
        pending = version.id
        problem = nil
        authentication = Task { @MainActor in
            do {
                let value = try await bridge.inspectReviewedVersion(conflict, versionID: version.id, generationIsCurrent: {
                    admission() && active && context == request && !Task.isCancelled
                })
                guard !Task.isCancelled, active, context == request, admission() else { return }
                Motion.animate(Look.quick) {
                    inspections[version.id] = value
                    if case .deletion = value { reviewed.insert(version.id) }
                    pending = nil
                }
                expiry[version.id]?.cancel()
                expiry[version.id] = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard context == request else { return }
                    forget(version.id)
                }
            } catch {
                guard active, context == request, !Task.isCancelled else { return }
                pending = nil
                problem = (error as? ICloudSecrets.Failure)?.localizedDescription
                    ?? "This version could not be inspected. Sync again and try the review once more."
            }
            if context == request { authentication = nil }
        }
    }

    private func select(_ version: ICloudSecrets.CloudVersion) {
        guard reviewed.contains(version.id), active, admission(), !choosing else { return }
        clear()
        choosing = true
        Task { @MainActor in
            await choose(conflict, .useCloudVersion(version.id))
            choosing = false
            dismiss()
        }
    }

    private func forget(_ identifier: UUID) {
        Motion.instant {
            inspections.removeValue(forKey: identifier)
            revealed.remove(identifier)
            reviewed.remove(identifier)
        }
        expiry.removeValue(forKey: identifier)?.cancel()
    }

    private func clear() {
        context = UUID()
        authentication?.cancel()
        authentication = nil
        for task in expiry.values { task.cancel() }
        expiry.removeAll()
        Motion.instant {
            inspections.removeAll()
            revealed.removeAll()
            reviewed.removeAll()
            pending = nil
        }
    }
}
