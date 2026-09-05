import AppKit
import SwiftUI

/// One download in the Library's footer popover.
///
/// Arc's row is three lines' worth of information in two: what the file is called, how much
/// of it has arrived out of how much there is, how long the rest will take — and the verbs
/// that apply to it right now. A row that only says "downloading…" leaves the user watching
/// a bar with no idea whether to wait.
struct DownloadRow: View {
    @ObservedObject var item: Downloads.Item
    /// The manager this row's item actually belongs to.
    let downloads: Downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name).lineLimit(1).truncationMode(.middle).font(Look.small)
                Spacer(minLength: Look.inset)
                buttons
            }
            // The size line. Present on every row that has bytes to talk about, so the row
            // does not change height as a download finishes.
            if !detail.isEmpty {
                Text(detail).font(Look.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            switch item.state {
            case .running:
                ProgressView(value: item.fraction).progressViewStyle(.linear)
                    .accessibilityHidden(true)
            case .done: EmptyView()
            case .failed(let why):
                // Paused and cancelled are not failures, and red would say they were.
                Text(why).font(Look.caption).lineLimit(2)
                    .foregroundStyle(item.status == .paused ? AnyShapeStyle(.secondary)
                                                            : AnyShapeStyle(.red))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(spoken)
        .accessibilityActions { actions }
    }

    // MARK: The verbs

    @ViewBuilder private var buttons: some View {
        switch item.status {
        case .done:
            // A renamed download is done, so Undo Rename sits beside Open rather than in an
            // else-branch it could never reach.
            if TidyDownloads.canUndo(item) {
                verb("Undo Rename", quiet: true) { _ = TidyDownloads.undo(item, in: downloads) }
                    .accessibilityHidden(true)
            }
            verb("Open") { downloads.open(item) }.accessibilityHidden(true)
            verb("Show", quiet: true) { downloads.reveal(item) }.accessibilityHidden(true)
        case .running:
            verb("Pause", quiet: true) { downloads.pause(item) }.accessibilityHidden(true)
            verb("Cancel", quiet: true) { downloads.cancel(item) }.accessibilityHidden(true)
        case .paused:
            if downloads.canResume(item) {
                verb("Resume") { _ = downloads.resume(item) }.accessibilityHidden(true)
            }
            verb("Cancel", quiet: true) { downloads.cancel(item) }.accessibilityHidden(true)
        case .missing, .failed:
            verb("Remove", quiet: true) { downloads.forget(item) }.accessibilityHidden(true)
        }
    }

    /// The same verbs for VoiceOver, which reads one row rather than a row of buttons.
    @ViewBuilder private var actions: some View {
        switch item.status {
        case .done:
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.reveal(item) }
            if TidyDownloads.canUndo(item) {
                Button("Undo Rename") { _ = TidyDownloads.undo(item, in: downloads) }
            }
        case .running:
            Button("Pause") { downloads.pause(item) }
            Button("Cancel") { downloads.cancel(item) }
        case .paused:
            if downloads.canResume(item) { Button("Resume") { _ = downloads.resume(item) } }
            Button("Cancel") { downloads.cancel(item) }
        case .missing, .failed:
            Button("Remove") { downloads.forget(item) }
        }
    }

    private func verb(_ title: String, quiet: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(Look.caption)
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
    }

    // MARK: The words

    /// "1.5 MB of 3.0 MB — 4 seconds left" while it runs, "3.0 MB" once it is there.
    private var detail: String {
        let size = Downloads.sizeText(received: item.received, total: item.total,
                                      done: item.status == .done)
        guard item.status == .running else { return size }
        let eta = Downloads.etaText(seconds: Downloads.secondsRemaining(
            received: item.received, total: item.total, bytesPerSecond: item.bytesPerSecond))
        return eta.isEmpty ? size : "\(size) — \(eta)"
    }

    /// The bar, the size and the state, in one sentence.
    private var spoken: String {
        switch item.state {
        case .running:         "downloading, \(Int(item.fraction * 100)) percent, \(detail)"
        case .done:            "finished, \(detail)"
        case .failed(let why): item.status == .paused ? "paused, \(detail)" : "failed, \(why)"
        }
    }
}
