import AppKit
import WebKit

/// ponytail: WKDownload still does the transfer, the resume data and the progress
/// reporting. What it does not do is remember anything across a launch, so this file is
/// the destination policy, a JSON list on disk per profile, and the pause/resume plumbing.
@MainActor final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {

    /// Resolves per profile, exactly like `Store.shared`, and by the same suffix rule — the
    /// default profile's file is plain `downloads.json`.
    /// ponytail ceiling: a view that grabbed `Downloads.shared` keeps the old profile's
    /// object until SwiftUI rebuilds it, and `Engine` attaches to whatever profile is
    /// active at that instant rather than the tab's own. Both are one line to fix in files
    /// I do not own.
    static var shared: Downloads { manager(for: ProfileManager.shared.active.id) }

    private static var cache: [UUID: Downloads] = [:]

    static func manager(for id: UUID) -> Downloads {
        if let hit = cache[id] { return hit }
        let fresh = Downloads(profileID: id, directory: Store.directory)
        cache[id] = fresh
        return fresh
    }

    /// Drop the list and both on-disk files. Call this when a profile is deleted.
    static func forget(_ id: UUID, in dir: URL = Store.directory) {
        cache[id] = nil
        try? FileManager.default.removeItem(at: listURL(for: id, in: dir))
        try? FileManager.default.removeItem(at: resumeDir(for: id, in: dir))
    }

    /// Retention policy: the newest 200 *finished* entries per profile (done, missing or
    /// failed-for-good). Anything running or paused is exempt from the cap — the list is
    /// the only handle on those, so evicting one would strand a transfer the user can
    /// still finish. Trimming happens on every save, so it is bounded, not swept.
    static let historyLimit = 200

    let profileID: UUID
    let directory: URL
    /// A sandboxed instance never registers for app notifications and never builds a
    /// WKWebView. `check()` uses one.
    private let sandboxed: Bool

    @Published var items: [Item] = []

    /// Where finished files land. A stored property only so a harness can point it at a
    /// temp folder; nothing in the app ever changes it.
    var destinationDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    init(profileID: UUID = ProfileManager.defaultID,
         directory: URL = Store.directory,
         sandboxed: Bool = false) {
        self.profileID = profileID
        self.directory = directory
        self.sandboxed = sandboxed
        super.init()
        load()
        guard !sandboxed else { return }
        // Quitting mid-download is the interruption people actually hit; see `pauseAll`.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseAll() }
        }
    }

    // MARK: The list

    /// The row as it is shown and as it is stored. `state` is deliberately still the three
    /// cases it always had, because UI.swift switches over it exhaustively and I cannot
    /// edit that file; `status` is the honest one. ponytail: two fields beat forking the UI.
    @MainActor final class Item: ObservableObject, Identifiable {
        let id: UUID
        /// nil for a restored row and for anything interrupted — the WKDownload died with
        /// the process, or with the connection, that owned it.
        private(set) var download: WKDownload?
        @Published var name: String
        /// Destination on disk. Kept spelled `url` because UI.swift and `reveal` read it.
        @Published var url: URL?
        @Published var source: URL?
        @Published var fraction = 0.0
        @Published var state: State = .running
        @Published var received: Int64 = 0
        @Published var total: Int64 = 0
        @Published var completed: Date?
        @Published var status: Status = .running

        /// Basename of the resume blob, or nil when there is nothing to resume from.
        fileprivate var resumeFile: String?
        /// Distinguishes "the user pressed pause" from "the network fell over" — the two
        /// need different words when the resume data turns out not to exist.
        fileprivate var pausedByUser = false
        fileprivate var onProgress: (() -> Void)?
        private var obs: NSKeyValueObservation?

        enum State: Equatable { case running, done, failed(String) }
        enum Status: Equatable {
            case running, paused, done, missing, failed
            /// Paused and interrupted rows are the ones a resume can be offered for.
            var isLive: Bool { self == .running || self == .paused }
        }

        init(_ download: WKDownload, name: String) {
            self.id = UUID()
            self.name = name
            watch(download)
        }

        fileprivate init(record: Record) {
            id = record.id
            name = record.name
            url = record.destination
            source = record.source
            total = record.total
            received = record.received
            completed = record.completed
            resumeFile = record.resumeFile
            fraction = record.total > 0 ? min(1, Double(record.received) / Double(record.total)) : 0
            switch record.state {
            case "running": status = .running; state = .running
            case "done":    status = .done;    state = .done
            case "paused":  status = .paused;  state = .failed(record.reason.isEmpty ? "Paused" : record.reason)
            case "missing": status = .missing; state = .failed(Downloads.missingText)
            default:        status = .failed;  state = .failed(record.reason.isEmpty ? "Failed" : record.reason)
            }
        }

        fileprivate var record: Record {
            var reason = ""
            if case .failed(let why) = state { reason = why }
            let name: String
            switch status {
            case .running: name = "running"
            case .paused:  name = "paused"
            case .done:    name = "done"
            case .missing: name = "missing"
            case .failed:  name = "failed"
            }
            return Record(id: id, name: self.name, destination: url, source: source,
                          total: total, received: received, state: name, reason: reason,
                          completed: completed, resumeFile: resumeFile)
        }

        fileprivate func watch(_ d: WKDownload) {
            download = d
            obs = d.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fraction = p.fractionCompleted
                    self.received = p.completedUnitCount
                    if p.totalUnitCount > 0 { self.total = p.totalUnitCount }
                    self.onProgress?()
                }
            }
        }

        /// Stop observing and forget the WKDownload. Anything that ends a transfer calls
        /// this, so `items.first { $0.download === d }` can never match a dead download.
        fileprivate func unwatch() {
            obs = nil
            download = nil
        }
    }

    /// One row on disk. Filename, destination, source, size, bytes received, state and
    /// completion date, per the brief; plus the name of the resume blob, which lives in a
    /// separate file — see `resumeDir`.
    struct Record: Codable, Equatable {
        var id = UUID()
        var name: String
        var destination: URL?
        var source: URL?
        var total: Int64 = 0
        var received: Int64 = 0
        /// running | paused | done | missing | failed. A string, not the enum, so a future
        /// state cannot make an old JSON file undecodable.
        var state: String
        var reason: String = ""
        var completed: Date?
        var resumeFile: String?
    }

    static let missingText = "The file was moved or deleted."

    // MARK: Paths

    nonisolated static func listURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("downloads\(ProfileManager.suffix(id)).json")
    }

    /// Resume blobs get their own directory, one file per download, rather than a base64
    /// field in the index. WebKit's resume data carries the whole partial-response
    /// bookkeeping and runs from tens of kilobytes into megabytes; inlining it would mean
    /// rewriting (and inflating by a third) the entire list on every progress tick, and
    /// would make the index unreadable by eye. The blob is deleted the moment the download
    /// finishes, is cleared, or is proven stale.
    nonisolated static func resumeDir(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("downloads-resume\(ProfileManager.suffix(id))", isDirectory: true)
    }

    // MARK: Load and save

    private func load() {
        guard let data = try? Data(contentsOf: Self.listURL(for: profileID, in: directory)),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        items = records.map { r in
            var r = r
            // "running" on disk means the process died mid-transfer. There is no WKDownload
            // to adopt, so it is interrupted: resumable if a blob survived, dead if not.
            if r.state == "running" {
                r.state = r.resumeFile == nil ? "failed" : "paused"
                if r.reason.isEmpty { r.reason = r.resumeFile == nil ? "Interrupted by quitting" : "Paused" }
            }
            // History whose file the user has since deleted or moved must not offer a
            // broken "Show in Finder".
            if r.state == "done", let d = r.destination,
               !FileManager.default.fileExists(atPath: d.path) { r.state = "missing" }
            return Item(record: r)
        }
        for i in items { i.onProgress = { [weak self] in self?.throttledSave() } }
    }

    /// Trims to the cap and writes the index. Called on every state change and, throttled,
    /// while bytes are arriving.
    func save() {
        lastSave = .now
        var keep: [Item] = []
        var evicted: [Item] = []
        var finished = 0
        for i in items {
            if i.status.isLive { keep.append(i); continue }
            finished += 1
            if finished <= Self.historyLimit { keep.append(i) } else { evicted.append(i) }
        }
        for e in evicted { deleteResume(e) }
        if !evicted.isEmpty { items = keep }
        guard let data = try? JSONEncoder().encode(keep.map(\.record)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.listURL(for: profileID, in: directory))
    }

    private var lastSave = Date.distantPast

    /// Bytes arrive dozens of times a second; the index does not need to. One write a
    /// second keeps a hard quit's record within a second of the truth.
    private func throttledSave() {
        guard Date.now.timeIntervalSince(lastSave) > 1 else { return }
        save()
    }

    /// Insert a row that has no WKDownload behind it — a seam for `check()`, and the only
    /// way to put a synthetic record into the list.
    @discardableResult
    func add(_ record: Record) -> Item {
        let item = Item(record: record)
        item.onProgress = { [weak self] in self?.throttledSave() }
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Clears the history. Running and paused rows stay: the list is the only handle on
    /// them, and "clear" should not silently throw away a resumable transfer.
    func clear() {
        for i in items where !i.status.isLive { deleteResume(i) }
        items = items.filter(\.status.isLive)
        save()
    }

    /// Re-checks every finished row against the filesystem. Cheap enough to call whenever
    /// the downloads popover opens.
    func refreshMissing() {
        var changed = false
        for i in items where i.status == .done || i.status == .missing {
            let there = i.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let want: Item.Status = there ? .done : .missing
            if i.status != want {
                i.status = want
                i.state = there ? .done : .failed(Self.missingText)
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: Destination policy

    private func item(for d: WKDownload) -> Item? { items.first { $0.download === d } }

    func attach(_ download: WKDownload) { download.delegate = self }

    /// Never overwrite: "report.pdf", then "report 2.pdf". Unchanged behaviour, just lifted
    /// out of the delegate so `check()` can prove it against a temp directory instead of
    /// the user's real ~/Downloads.
    nonisolated static func uniqueDestination(in dir: URL, suggested: String,
                                              fm: FileManager = .default) -> URL {
        let safe = suggested.replacingOccurrences(of: "/", with: ":")
        var target = dir.appendingPathComponent(safe.isEmpty ? "download" : safe)
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return target
    }

    /// Straight to ~/Downloads, never overwriting.
    /// ponytail: no save panel by default — that is what every browser does, and the
    /// "always ask" preference is a checkbox for the day there is a settings window.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        // A resumed transfer must land back on its own partial file. Uniquifying here would
        // hand WebKit an empty "report 2.pdf" and restart from zero — exactly the silent
        // failure the brief forbids.
        if let entry = resuming.removeValue(forKey: ObjectIdentifier(download)) {
            entry.status = .running
            entry.state = .running
            save()
            completionHandler(entry.url)
            return
        }
        let target = Self.uniqueDestination(in: destinationDirectory, suggested: suggestedFilename)
        let entry = Item(download, name: target.lastPathComponent)
        entry.url = target
        entry.source = download.originalRequest?.url ?? response.url
        entry.total = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        entry.onProgress = { [weak self] in self?.throttledSave() }
        items.insert(entry, at: 0)
        save()
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let i = item(for: download) else { return }
        TidyDownloads.tidy(download, in: self)      // before unwatch() nils out item.download
        i.unwatch()
        i.state = .done
        i.status = .done
        i.fraction = 1
        // The file on disk is the only byte count that cannot be wrong.
        if let p = i.url?.path,
           let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? Int64 {
            i.received = size
            i.total = size
        }
        i.completed = .now
        deleteResume(i)
        save()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let i = item(for: download) else { return }
        i.unwatch()
        finish(i, error: error.localizedDescription, resumeData: resumeData)
    }

    /// One place decides what an interrupted transfer becomes: resumable if WebKit handed
    /// back resume data, dead otherwise.
    private func finish(_ i: Item, error: String, resumeData: Data?) {
        if let data = resumeData, !data.isEmpty {
            writeResume(data, for: i)
            i.status = .paused
            i.state = .failed(i.pausedByUser ? "Paused" : "Interrupted — \(error). Resume available.")
        } else {
            deleteResume(i)
            i.status = .failed
            i.state = .failed(i.pausedByUser
                              ? "Paused, but this server does not support resuming."
                              : error)
        }
        i.pausedByUser = false
        save()
    }

    // MARK: Pause and resume

    /// Items awaiting their `decideDestinationUsing` callback after a resume, keyed by the
    /// fresh WKDownload WebKit handed back.
    private var resuming: [ObjectIdentifier: Item] = [:]

    func pause(_ item: Item) {
        guard let d = item.download, item.status == .running else { return }
        item.pausedByUser = true
        item.status = .paused
        item.state = .failed("Pausing…")
        d.cancel { [weak self] data in
            guard let self else { return }
            item.unwatch()
            self.finish(item, error: "Paused", resumeData: data)
        }
    }

    /// Anything the user could still finish: paused, or interrupted with a blob on disk.
    func canResume(_ item: Item) -> Bool {
        item.status == .paused
            && Self.resumeBlocker(destination: item.url, resumeData: readResume(item)) == nil
    }

    /// Why a resume cannot work, or nil if it can. Pure — the record plus the filesystem,
    /// no network — so `check()` can prove the staleness rules offline.
    ///
    /// The `bplist00` sniff is the cheap half of "stale": WebKit's resume data is a keyed
    /// archive, so a truncated or hand-mangled blob is caught here instead of being handed
    /// to WebKit, which answers a bad blob by quietly starting a *new* download.
    nonisolated static func resumeBlocker(destination: URL?, resumeData: Data?,
                                          fm: FileManager = .default) -> String? {
        guard let data = resumeData, !data.isEmpty else {
            return "Cannot resume: the server did not offer a way to continue this download."
        }
        guard data.count > 8, data.prefix(8) == Data("bplist00".utf8) else {
            return "Cannot resume: the saved resume data is damaged."
        }
        guard let destination else { return "Cannot resume: this download has no destination." }
        guard fm.fileExists(atPath: destination.path) else {
            return "Cannot resume: the partial file was moved or deleted."
        }
        return nil
    }

    /// Restarts a paused or interrupted transfer. Returns false — and says why on the row —
    /// when it cannot, rather than starting over from zero.
    @discardableResult
    func resume(_ item: Item) -> Bool {
        let data = readResume(item)
        if let why = Self.resumeBlocker(destination: item.url, resumeData: data) {
            deleteResume(item)
            item.status = .failed
            item.state = .failed(why)
            save()
            return false
        }
        item.status = .running
        item.state = .running
        item.pausedByUser = false
        save()
        resumer.resumeDownload(fromResumeData: data!) { [weak self] d in
            guard let self else { return }
            self.resuming[ObjectIdentifier(d)] = item
            item.watch(d)
            d.delegate = self
        }
        return true
    }

    /// Quit is the common interruption, and `cancel` hands back its resume data
    /// asynchronously — after the process would already be gone. So spin the main runloop
    /// for up to two seconds. Ugly, and the only difference between a resumable download
    /// and a dead one on ⌘Q.
    func pauseAll() {
        let running = items.filter { $0.status == .running }
        guard !running.isEmpty else { return }
        for i in running { pause(i) }
        let deadline = Date.now.addingTimeInterval(2)
        while Date.now < deadline && running.contains(where: { $0.status == .paused && $0.resumeFile == nil }) {
            RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }
        save()
    }

    /// A private WKWebView purely to own `resumeDownload`. It is not displayed; the
    /// profile's data store is what carries the cookies the range request needs.
    private lazy var resumer: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = ProfileManager.dataStore(for: profileID)
        return WKWebView(frame: .zero, configuration: cfg)
    }()

    private func resumeURL(_ item: Item) -> URL {
        Self.resumeDir(for: profileID, in: directory)
            .appendingPathComponent("\(item.id.uuidString).resume")
    }

    private func writeResume(_ data: Data, for item: Item) {
        let dir = Self.resumeDir(for: profileID, in: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: resumeURL(item))) != nil else { return }
        item.resumeFile = resumeURL(item).lastPathComponent
    }

    private func readResume(_ item: Item) -> Data? {
        item.resumeFile == nil ? nil : try? Data(contentsOf: resumeURL(item))
    }

    private func deleteResume(_ item: Item) {
        try? FileManager.default.removeItem(at: resumeURL(item))
        item.resumeFile = nil
    }

    // MARK: Finder

    func reveal(_ item: Item) {
        guard let url = item.url else { return }
        // The row may have been finished weeks ago; do not open Finder onto nothing.
        guard FileManager.default.fileExists(atPath: url.path) else {
            item.status = .missing
            item.state = .failed(Self.missingText)
            save()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Offline check

    /// Everything here runs against throwaway temp directories: never the real
    /// Application Support folder, never ~/Downloads, never the network.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-downloads-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // --- Unique filename policy (pre-existing behaviour, must not regress) ---
        let dl = root.appendingPathComponent("dl", isDirectory: true)
        try? fm.createDirectory(at: dl, withIntermediateDirectories: true)
        assert("a free name is used as-is",
               uniqueDestination(in: dl, suggested: "report.pdf").lastPathComponent == "report.pdf")
        try? Data("a".utf8).write(to: dl.appendingPathComponent("report.pdf"))
        assert("report.pdf becomes report 2.pdf",
               uniqueDestination(in: dl, suggested: "report.pdf").lastPathComponent == "report 2.pdf")
        try? Data("b".utf8).write(to: dl.appendingPathComponent("report 2.pdf"))
        assert("...and then report 3.pdf",
               uniqueDestination(in: dl, suggested: "report.pdf").lastPathComponent == "report 3.pdf")
        try? Data("c".utf8).write(to: dl.appendingPathComponent("notes"))
        assert("an extensionless name still uniquifies",
               uniqueDestination(in: dl, suggested: "notes").lastPathComponent == "notes 2")
        assert("a slash in the suggested name cannot escape the directory",
               uniqueDestination(in: dl, suggested: "a/b.txt").deletingLastPathComponent().path == dl.path)
        assert("an empty suggested name falls back to 'download'",
               uniqueDestination(in: dl, suggested: "").lastPathComponent == "download")

        // --- Persistence round-trip ---
        let file = dl.appendingPathComponent("kept.zip")
        try? Data("payload".utf8).write(to: file)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let d = Downloads(profileID: ProfileManager.defaultID, directory: root, sandboxed: true)
        assert("a fresh profile starts with an empty list", d.items.isEmpty)
        d.add(Record(name: "kept.zip", destination: file,
                     source: URL(string: "https://example.com/kept.zip"),
                     total: 7, received: 7, state: "done", completed: when))
        assert("the index is written where the profile suffix says it goes",
               fm.fileExists(atPath: listURL(for: defaultProfile, in: root).path)
               && listURL(for: defaultProfile, in: root).lastPathComponent == "downloads.json")

        let again = Downloads(profileID: ProfileManager.defaultID, directory: root, sandboxed: true)
        let back = again.items.first
        assert("a finished download survives a relaunch", again.items.count == 1)
        assert("filename, destination and source round-trip",
               back?.name == "kept.zip" && back?.url == file
               && back?.source?.absoluteString == "https://example.com/kept.zip")
        assert("byte size and bytes received round-trip", back?.total == 7 && back?.received == 7)
        assert("the completion date round-trips", back?.completed == when)
        assert("a restored finished download reads as done",
               back?.status == .done && back?.state == .done)

        // --- Missing file detection ---
        try? fm.removeItem(at: file)
        let afterDelete = Downloads(profileID: ProfileManager.defaultID, directory: root, sandboxed: true)
        assert("a file deleted since the download is detected on load",
               afterDelete.items.first?.status == .missing)
        assert("a missing file is not offered as done, so no broken Show in Finder",
               afterDelete.items.first?.state != .done)
        afterDelete.reveal(afterDelete.items[0])
        assert("reveal on a missing file marks the row instead of opening Finder",
               afterDelete.items.first?.status == .missing)
        try? Data("payload".utf8).write(to: file)
        afterDelete.refreshMissing()
        assert("putting the file back makes the row whole again",
               afterDelete.items.first?.status == .done && afterDelete.items.first?.state == .done)

        // --- Interrupted-by-quitting ---
        let quitRoot = root.appendingPathComponent("quit", isDirectory: true)
        try? fm.createDirectory(at: quitRoot, withIntermediateDirectories: true)
        let partial = quitRoot.appendingPathComponent("big.iso")
        try? Data(repeating: 0x41, count: 1024).write(to: partial)
        let blob = quitRoot.appendingPathComponent("blob.resume")
        try? (Data("bplist00".utf8) + Data(repeating: 0, count: 64)).write(to: blob)

        // A row still marked "running" on disk: the process died mid-transfer, so the
        // index is written by hand rather than through `add`, which is what a crash does.
        func plant(_ records: [Record], in dir: URL) {
            try? JSONEncoder().encode(records).write(to: listURL(for: defaultProfile, in: dir))
        }
        var live = Record(name: "big.iso", destination: partial, total: 1_000_000,
                          received: 1024, state: "running")
        plant([live], in: quitRoot)
        let deadReload = Downloads(profileID: ProfileManager.defaultID, directory: quitRoot, sandboxed: true)
        assert("a 'running' row with no resume data comes back as failed, not running",
               deadReload.items.first?.status == .failed)
        assert("...and says it was interrupted",
               deadReload.items.first?.state == .failed("Interrupted by quitting"))
        assert("a dead row is never offered as resumable",
               deadReload.canResume(deadReload.items[0]) == false)

        // Same row, but a resume blob survived the quit.
        let resumeHome = resumeDir(for: defaultProfile, in: quitRoot)
        try? fm.createDirectory(at: resumeHome, withIntermediateDirectories: true)
        live.resumeFile = "\(live.id.uuidString).resume"
        try? fm.copyItem(at: blob, to: resumeHome.appendingPathComponent(live.resumeFile!))
        plant([live], in: quitRoot)
        let liveReload = Downloads(profileID: ProfileManager.defaultID, directory: quitRoot, sandboxed: true)
        assert("a 'running' row with resume data comes back paused, not running",
               liveReload.items.first?.status == .paused)
        assert("a download interrupted by quitting is offered for resume",
               liveReload.canResume(liveReload.items[0]))

        // --- Resume-data staleness ---
        assert("no resume data blocks the resume",
               resumeBlocker(destination: partial, resumeData: nil) != nil)
        assert("empty resume data blocks the resume",
               resumeBlocker(destination: partial, resumeData: Data()) != nil)
        assert("resume data that is not a keyed archive blocks the resume",
               resumeBlocker(destination: partial, resumeData: Data(repeating: 0xFF, count: 128)) != nil)
        let good = try? Data(contentsOf: blob)
        assert("intact resume data plus an intact partial file permits the resume",
               resumeBlocker(destination: partial, resumeData: good) == nil)
        try? fm.removeItem(at: partial)
        assert("a deleted partial file blocks the resume rather than restarting from zero",
               resumeBlocker(destination: partial, resumeData: good) != nil)
        let stale = liveReload.items[0]
        assert("resume() refuses when the partial file is gone", liveReload.resume(stale) == false)
        assert("a refused resume says why, in words",
               { if case .failed(let why) = stale.state { return why.contains("partial file") }; return false }())
        assert("a refused resume stops offering itself", liveReload.canResume(stale) == false)
        assert("a refused resume drops the useless blob",
               !fm.fileExists(atPath: resumeHome.appendingPathComponent("\(stale.id.uuidString).resume").path))

        // --- Per-profile isolation ---
        let workID = UUID()
        let work = Downloads(profileID: workID, directory: root, sandboxed: true)
        work.add(Record(name: "work-only.csv", destination: dl.appendingPathComponent("work-only.csv"),
                        state: "done"))
        assert("a second profile's list is stored under its own name",
               listURL(for: workID, in: root).lastPathComponent
                   == "downloads-\(workID.uuidString.lowercased()).json")
        assert("a download made in one profile does not appear in another",
               Downloads(profileID: ProfileManager.defaultID, directory: root, sandboxed: true)
                   .items.map(\.name) == ["kept.zip"])
        assert("...and the other profile sees only its own",
               Downloads(profileID: workID, directory: root, sandboxed: true)
                   .items.map(\.name) == ["work-only.csv"])
        assert("resume blobs are per profile too",
               resumeDir(for: workID, in: root) != resumeDir(for: defaultProfile, in: root))
        forget(workID, in: root)
        assert("forgetting a profile deletes its list",
               !fm.fileExists(atPath: listURL(for: workID, in: root).path))
        assert("forgetting a profile leaves the other profile's list alone",
               fm.fileExists(atPath: listURL(for: defaultProfile, in: root).path))

        // --- History cap and clear ---
        let capRoot = root.appendingPathComponent("cap", isDirectory: true)
        try? fm.createDirectory(at: capRoot, withIntermediateDirectories: true)
        let capped = Downloads(profileID: ProfileManager.defaultID, directory: capRoot, sandboxed: true)
        // add() inserts at the front, so #0 is the oldest and #(n-1) the newest.
        for n in 0..<(historyLimit + 25) {
            capped.add(Record(name: "f\(n)", destination: capRoot.appendingPathComponent("f\(n)"),
                              state: "done"))
        }
        assert("history is capped at the stated limit", capped.items.count == historyLimit)
        assert("the cap drops the oldest, keeps the newest",
               capped.items.first?.name == "f\(historyLimit + 24)"
               && capped.items.last?.name == "f25")
        assert("the cap survives a relaunch",
               Downloads(profileID: ProfileManager.defaultID, directory: capRoot, sandboxed: true)
                   .items.count == historyLimit)
        // A live row must be exempt: evicting it would strand a resumable transfer.
        var pausedRec = Record(name: "half.iso", destination: capRoot.appendingPathComponent("half.iso"),
                               state: "paused")
        pausedRec.reason = "Paused"
        capped.items.append(capped.add(pausedRec))  // once at the front, once at the very back
        capped.items.removeFirst()
        capped.save()
        assert("a paused row is exempt from the cap",
               capped.items.contains { $0.name == "half.iso" })
        capped.clear()
        assert("clear empties the history", capped.items.count == 1)
        assert("clear keeps a paused download, which is the only handle on it",
               capped.items.first?.name == "half.iso")
        assert("clear survives a relaunch",
               Downloads(profileID: ProfileManager.defaultID, directory: capRoot, sandboxed: true)
                   .items.map(\.name) == ["half.iso"])

        return out
    }

    private static var defaultProfile: UUID { ProfileManager.defaultID }
}
