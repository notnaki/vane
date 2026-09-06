import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a download looks like in the Library's list: its icon, and the one line of grey under
/// its name. The row itself is `LibraryRow`, shared with the archive, so the two lists cannot
/// drift apart; only these two things are a download's own.
///
/// Arc's row says what the file *is* once it is there ("Disk Image from atkgear.com") and what
/// is *happening to it* while it is not ("1.5 MB of 3.0 MB — 4 seconds left"). A row that only
/// ever said "downloading…" leaves the user watching a bar with no idea whether to wait; a
/// finished row still talking in bytes would be a progress display for something that stopped.
extension Downloads.Item {
    var subtitle: String {
        switch status {
        case .running:
            let size = Downloads.sizeText(received: received, total: total)
            let eta = Downloads.etaText(seconds: Downloads.secondsRemaining(
                received: received, total: total, bytesPerSecond: bytesPerSecond))
            return eta.isEmpty ? size : "\(size) — \(eta)"
        case .paused:
            return "Paused — \(Downloads.sizeText(received: received, total: total))"
        case .missing:
            return Downloads.missingText
        case .failed:
            if case .failed(let why) = state, !why.isEmpty { return why }
            return "Failed"
        case .done:
            return Library.describe(name: name, source: source)
        }
    }

    /// The same row for VoiceOver, which cannot see how far the ring has gone round — and,
    /// on a finished row, wants the size the sighted row trades for the file's kind.
    var spoken: String {
        switch status {
        case .running: "Downloading, \(Int(fraction * 100)) percent, \(subtitle)"
        case .done:    "\(subtitle), \(Downloads.sizeText(received: received, total: total, done: true))"
        case .paused, .missing, .failed: subtitle
        }
    }
}

/// The file's own icon, the way the Finder draws it — and while it is still arriving, a ring
/// instead, because the icon of a half-downloaded file says nothing about how far along it is
/// and the ring is the only thing on the row that moves.
struct DownloadIcon: View {
    @ObservedObject var item: Downloads.Item
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if item.status.isLive {
            ZStack {
                Circle().stroke(Look.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: Swift.max(item.fraction, 0.02))  // never an invisible ring
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))                      // noon, the way a clock runs
                    .animation(reduceMotion ? nil : Look.quick, value: item.fraction)
            }
            .frame(width: Look.iconRing, height: Look.iconRing)
            // The row already says how far along it is, in words.
            .accessibilityHidden(true)
        } else {
            Image(nsImage: icon).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    /// `icon(forFile:)` for a file that is there, and the declared type's own icon for one
    /// that is not: a row whose file has been thrown away still has to look like what it was.
    private var icon: NSImage {
        if let url = item.url, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = URL(fileURLWithPath: item.name).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
