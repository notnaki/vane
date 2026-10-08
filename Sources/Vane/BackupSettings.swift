import SwiftUI

struct BackupSettings: View {
    @ObservedObject var controller: BackupController
    var body: some View {
        SettingsCard {
            SettingsRow("Your saved library") {
                HStack {
                    Button("Export Backup…") { controller.showExportPanel() }
                    Button("Restore Backup…") { controller.showRestorePanel() }
                }
                .disabled(controller.busy)
            }
            Footnote("Includes all profiles, Spaces, tabs, bookmarks, history, settings, Easels, and the offline Reading Queue with saved images. Exported backups are not encrypted. Passwords, cookies, sign-ins, downloaded files, and external extension folders are excluded.")
            if controller.busy {
                HStack { ProgressView().controlSize(.small); Text(controller.progress.isEmpty ? "Saving a recovery point…" : controller.progress) }
                    .font(Look.footnote).padding(Look.cardInset)
                    .accessibilityLabel(controller.progress.isEmpty ? "Saving a recovery point" : controller.progress)
            }
            if let status = controller.status { Footnote(status) }
            if let error = controller.error { errorRow(error) }
            SettingsRow("Automatic local recovery") {
                Text("Hourly · Latest 10").font(Look.footnote).foregroundStyle(.secondary)
            }
            if let point = controller.points.first(where: { $0.diagnostic == nil }) {
                Footnote("Last usable point: \(point.date.formatted(date: .abbreviated, time: .shortened)).")
            } else { Footnote("No usable recovery point yet.") }
            if let error = controller.recoveryError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).foregroundStyle(.red).font(Look.footnote)
                    Button("Retry Recovery Point") { Task { await controller.retryRecovery() } }
                        .disabled(controller.busy)
                }.padding(Look.cardInset)
            }
            ForEach(controller.points) { point in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.date.formatted(date: .abbreviated, time: .shortened)).font(Look.text)
                        Text("\(point.reason.title) · \(ByteCountFormatter.string(fromByteCount: Int64(point.size), countStyle: .file))")
                            .font(Look.footnote).foregroundStyle(.secondary)
                        if let diagnostic = point.diagnostic {
                            Text("Unavailable: \(diagnostic)").font(Look.footnote).foregroundStyle(.red)
                                .lineLimit(2).help(diagnostic)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Preview…") { Task { await controller.previewRestore(from: point.url) } }
                        .disabled(controller.busy || point.diagnostic != nil)
                        .accessibilityLabel("Preview recovery point from \(point.date.formatted())")
                }.padding(Look.cardInset)
            }
            Footnote("A recovery point is saved after startup and hourly when saved data changes, and before every restore. Local points share this Mac's disk; export a backup to another disk for protection against disk loss. Erase Everything also removes local recovery points.")
        }
        .onAppear { controller.reloadPoints() }
        .sheet(item: Binding(get: { controller.preview }, set: { if $0 == nil { controller.cancelPreview() } })) { candidate in
            BackupPreviewView(candidate: candidate, controller: controller)
        }
    }
    private func errorRow(_ message: String) -> some View {
        Text(message).font(Look.footnote).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Look.cardInset)
    }
}

struct BackupPreviewView: View {
    let candidate: BackupCandidate
    @ObservedObject var controller: BackupController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore this backup?").font(.title2.weight(.semibold))
            Text("\(candidate.archive.created.formatted(date: .abbreviated, time: .shortened)) · Vane \(candidate.archive.appVersion)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("This replaces all regular profiles' saved data and settings. A recovery point preserves your current data first. Vane will restart.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(candidate.incoming.profiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.name).font(.headline)
                            Text("\(profile.spaces) Spaces · \(profile.tabs) tabs · \(profile.bookmarks) bookmarks · \(profile.history) history entries · \(profile.easels) Easels · \(profile.readingQueue) saved articles")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Text("Backup: \(candidate.incoming.settings) saved settings across \(candidate.incoming.profiles.count) profiles.")
                    if let current = candidate.current {
                        Text("Current saved library: \(current.profiles.count) profiles · \(current.spaces) Spaces · \(current.tabs) tabs · \(current.bookmarks) bookmarks · \(current.history) history entries · \(current.easels) Easels · \(current.readingQueue) saved articles · \(current.settings) settings.")
                    }
                    if let message = candidate.currentError {
                        Text("Current data could not be previewed. Its original files will still be preserved before restoring.")
                            .foregroundStyle(.orange).help(message)
                    }
                    Text("Passwords, cookies, website sign-ins, downloaded files, and external extension folders are excluded.")
                    if candidate.incoming.hasExternalFolders {
                        Text("On another Mac, you may need to select your external folders again.")
                    }
                }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }.frame(maxHeight: 320)
            if controller.busy {
                HStack { ProgressView().controlSize(.small); Text(controller.progress) }.font(.subheadline)
            }
            if let error = controller.error { Text(error).font(.subheadline).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { controller.cancelPreview() }.keyboardShortcut(.cancelAction)
                Button("Restore and Restart", role: .destructive) { Task { await controller.restorePreview() } }
            }.disabled(controller.busy)
        }
        .padding(24).frame(width: 570)
        .interactiveDismissDisabled(controller.busy)
    }
}
