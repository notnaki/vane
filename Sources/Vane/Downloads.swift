import AppKit
import WebKit

/// ponytail: WKDownload already does the transfer, the resume data and the progress
/// reporting. This is only the destination policy plus a list to show.
@MainActor final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()
    @Published var items: [Item] = []

    @MainActor final class Item: ObservableObject, Identifiable {
        let id = UUID()
        let download: WKDownload
        @Published var name: String
        @Published var url: URL?
        @Published var fraction = 0.0
        @Published var state: State = .running
        private var obs: NSKeyValueObservation?

        enum State: Equatable { case running, done, failed(String) }

        init(_ download: WKDownload, name: String) {
            self.download = download
            self.name = name
            obs = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
                MainActor.assumeIsolated { self?.fraction = p.fractionCompleted }
            }
        }
    }

    private func item(for d: WKDownload) -> Item? { items.first { $0.download === d } }

    func attach(_ download: WKDownload) { download.delegate = self }

    /// Straight to ~/Downloads, never overwriting: "report.pdf", then "report 2.pdf".
    /// ponytail: no save panel by default — that is what every browser does, and the
    /// "always ask" preference is a checkbox for the day there is a settings window.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = suggestedFilename.replacingOccurrences(of: "/", with: ":")
        var target = dir.appendingPathComponent(safe.isEmpty ? "download" : safe)
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let name = "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            target = dir.appendingPathComponent(name)
            n += 1
        }
        let entry = Item(download, name: target.lastPathComponent)
        entry.url = target
        items.insert(entry, at: 0)
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let i = item(for: download) else { return }
        i.state = .done
        i.fraction = 1
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        item(for: download)?.state = .failed(error.localizedDescription)
    }

    func reveal(_ item: Item) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
