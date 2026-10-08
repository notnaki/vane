import AppKit
import WebKit

/// Opt-in signed-process fixture. The Python driver retains its HTTP server and data
/// directory across two app launches, exercising the real willTerminate pause hook.
@MainActor enum DownloadChecks {
    static func run(directory: String, resume: Bool) async -> Never {
        do {
            guard let endpoint = ProcessInfo.processInfo.environment["VANE_DOWNLOAD_FIXTURE_URL"],
                  let url = URL(string: endpoint), url.host == "127.0.0.1", url.scheme == "http" else {
                throw Failure.message("Download fixture requires a loopback HTTP URL")
            }
            let root = URL(fileURLWithPath: directory)
            let files = root.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let downloads = Downloads(directory: root)
            downloads.destinationDirectory = files
            DownloadLocation.setAskEveryTime(false, for: downloads.profileID)
            TidyDownloads.enabled = false
            if resume {
                guard let row = downloads.items.first, row.status == .paused, downloads.canResume(row),
                      downloads.resume(row) else { throw Failure.message("Restart did not restore a resumable row") }
                try await wait { row.download == nil && row.status != .running }
                let expected = Data((0..<262144).map { UInt8($0 % 251) })
                guard row.status == .done, let file = row.url,
                      try Data(contentsOf: file) == expected else {
                    throw Failure.message("Restart resume did not produce complete bytes: \(row.subtitle)")
                }
                print("PASS downloadcheck: restart resumed complete bytes at \(file.path)")
                exit(0)
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = ProfileManager.dataStore(for: downloads.profileID)
            let web = WKWebView(frame: .zero, configuration: config)
            let download = await web.startDownload(using: URLRequest(url: url))
            downloads.attach(download, from: web)
            try await wait { downloads.items.first?.received ?? 0 > 0 }
            if ProcessInfo.processInfo.environment["VANE_DOWNLOAD_FIXTURE_PAUSE_FIRST"] == "1",
               let row = downloads.items.first {
                downloads.pause(row)
            }
            print("PASS downloadcheck: quitting a live transfer through willTerminate")
            withExtendedLifetime((downloads, web)) { NSApplication.shared.terminate(nil) }
            throw Failure.message("App termination unexpectedly returned")
        } catch {
            fputs("FAIL downloadcheck: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.message("Download fixture timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum Failure: Error { case message(String) }
}
