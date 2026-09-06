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
    @ObservedObject private var thumbnails = Thumbnails.shared

    var body: some View {
        if item.status.isLive {
            ProgressRing(fraction: item.fraction, track: true)
        } else if let picture {
            // A picture fills its square and is cropped to it: a photo letterboxed into a
            // 20pt box is four grey bars and a stamp.
            Image(nsImage: picture).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fill)
                // Sized *before* it is clipped: filled to the box and then cut to it, or a
                // wide photo spills out of the row and over the title beside it.
                .frame(width: Look.libraryThumb, height: Look.libraryThumb)
                .clipShape(.rect(cornerRadius: Look.captionGap))
                .accessibilityHidden(true)
        } else {
            // A Finder icon is not square — a .dmg is taller than it is wide — so it is fitted
            // rather than filled, which would crop its edges off.
            Image(nsImage: FileIcons.icon(path: item.status == .done ? item.url?.path : nil,
                                          name: item.name))
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
                .task { ask() }
        }
    }

    /// The file itself, once it has been decoded. Nothing here waits for it: the row draws
    /// the Finder's icon and swaps when the picture lands.
    private var picture: NSImage? {
        guard item.status == .done, let url = item.url, Library.isImage(name: item.name)
        else { return nil }
        return thumbnails.image(for: url)
    }

    private func ask() {
        guard item.status == .done, let url = item.url, Library.isImage(name: item.name)
        else { return }
        thumbnails.want(url)
    }
}

/// Finder icons, kept. `icon(forFile:)` reads the file, and a row asked for one on every
/// render — a pointer moving down a list of downloads was hitting the disk per row per
/// frame. Keyed by what the answer actually depends on, so nothing has to invalidate it: a
/// path (the file is there and the Finder has an icon for it) or a file extension (it is not,
/// and the declared type's icon is the best that can be said).
///
/// ponytail: an unbounded dictionary, because the list it serves is capped at
/// `Downloads.historyLimit` and the icons are shared `NSImage`s the system already holds.
@MainActor enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    /// `path` only for a download whose file is known to be there — `Downloads.refreshMissing`
    /// is what decides that, so this never stats the disk itself.
    static func icon(path: String?, name: String) -> NSImage {
        let ext = URL(fileURLWithPath: name).pathExtension
        let key = path ?? ".\(ext)"
        if let hit = cache[key] { return hit }
        let image = path.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[key] = image
        return image
    }
}
