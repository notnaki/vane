import AppKit
import WebKit

/// ponytail: WKDownload still does the transfer, the resume data and the progress
/// reporting. What it does not do is remember anything across a launch, so this file is
/// the destination policy, a JSON list on disk per profile, and the pause/resume plumbing.
@MainActor final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {

    /// Resolves per profile, exactly like `Store.shared`, and by the same suffix rule — the
    /// default profile's file is plain `downloads.json`.
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

    /// Where finished files land: the profile's own folder, unless a harness has pointed
    /// this instance somewhere else.
    var destinationDirectory: URL {
        get { override ?? DownloadLocation.directory(for: profileID) }
        set { override = newValue }
    }
    private var override: URL?

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
        /// How fast bytes are arriving, smoothed. Zero until two samples are in — an ETA
        /// off the first tick of a transfer is a number made up.
        @Published var bytesPerSecond: Double = 0

        /// The last rate sample: when it was taken and how many bytes had arrived by then.
        private var sampledAt: Date?
        private var sampledBytes: Int64 = 0

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
                    self.sample()
                    self.onProgress?()
                }
            }
        }

        /// One rate sample every half second, folded into the last one. Sampling on every
        /// progress tick instead would read whatever the last packet happened to be, and an
        /// ETA that jumps between "2 seconds" and "4 minutes" is worse than none.
        private func sample(now: Date = .now) {
            guard let then = sampledAt else {
                sampledAt = now
                sampledBytes = received
                return
            }
            let elapsed = now.timeIntervalSince(then)
            guard elapsed >= 0.5 else { return }
            bytesPerSecond = Downloads.smoothed(previous: bytesPerSecond,
                                                bytes: received - sampledBytes, over: elapsed)
            sampledAt = now
            sampledBytes = received
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

    /// Straight to the profile's download folder, never overwriting — unless the profile
    /// asks to be asked, in which case a save panel decides and cancelling it cancels the
    /// download rather than leaving a row that never starts.
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
        var target = Self.uniqueDestination(in: destinationDirectory, suggested: suggestedFilename)
        if DownloadLocation.askEveryTime(for: profileID) {
            guard let chosen = askWhereToSave(suggested: suggestedFilename,
                                              in: destinationDirectory) else {
                completionHandler(nil)      // cancelled: no file, and no row either
                return
            }
            target = chosen
        }
        let entry = Item(download, name: target.lastPathComponent)
        entry.url = target
        entry.source = download.originalRequest?.url ?? response.url
        entry.total = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        entry.onProgress = { [weak self] in self?.throttledSave() }
        items.insert(entry, at: 0)
        save()
        completionHandler(target)
    }

    /// The save panel, run where WebKit is waiting for an answer. Modal on purpose: the
    /// delegate's completion handler is the download, and there is nothing useful to do
    /// with the window until the user has said where the file goes.
    private func askWhereToSave(suggested: String, in directory: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested.isEmpty ? "download" : suggested
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.message = "Where should this download be saved?"
        return panel.runModal() == .OK ? panel.url : nil
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

    // MARK: Cancel

    /// Stop a transfer for good and take the half-written file with it. Distinct from
    /// `pause`, which keeps both the partial file and the resume data on purpose.
    func cancel(_ item: Item) {
        item.pausedByUser = false
        if let d = item.download {
            d.cancel { _ in }               // the resume data is deliberately dropped
            item.unwatch()
        }
        deleteResume(item)
        if let url = item.url { try? FileManager.default.removeItem(at: url) }
        item.status = .failed
        item.state = .failed(Self.cancelledText)
        item.bytesPerSecond = 0
        save()
    }

    static let cancelledText = "Cancelled"

    /// Takes a row out of the list. The file on disk is left alone: the Library is a list
    /// of what happened, and forgetting an entry is not the same as deleting a download.
    func forget(_ item: Item) {
        deleteResume(item)
        items.removeAll { $0 === item }
        save()
    }

    // MARK: Finder

    /// Clicking a finished download opens it, the way it does in Arc's Library.
    func open(_ item: Item) {
        guard let url = item.url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            item.status = .missing
            item.state = .failed(Self.missingText)
            save()
            return
        }
        NSWorkspace.shared.open(url)
    }

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

    // MARK: Words

    /// A byte count as a person reads it. Decimal units, because that is what the Finder,
    /// every browser and every server's Content-Length agree on.
    ///
    /// Pure and locale-free on purpose: `ByteCountFormatter` is neither, and a row that
    /// reads differently on a French machine is a row that cannot be asserted.
    nonisolated static func byteText(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return bytes == 1 ? "1 byte" : "\(max(0, bytes)) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000, unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        // One decimal while the number is small enough for it to mean something.
        return value < 10 ? String(format: "%.1f %@", value, units[unit])
                          : String(format: "%.0f %@", value, units[unit])
    }

    /// "1.5 MB of 3.0 MB" while it runs, "3.0 MB" when it is done or the server never said
    /// how big the file was.
    nonisolated static func sizeText(received: Int64, total: Int64, done: Bool = false) -> String {
        guard !done else { return byteText(total > 0 ? total : received) }
        guard total > received else { return byteText(received) }
        return "\(byteText(received)) of \(byteText(total))"
    }

    /// How long the rest of the file will take, or nil when that cannot be known yet — an
    /// unknown size, a stalled transfer, or a rate we have not sampled twice.
    nonisolated static func secondsRemaining(received: Int64, total: Int64,
                                             bytesPerSecond: Double) -> Double? {
        guard total > received, bytesPerSecond > 0 else { return nil }
        return Double(total - received) / bytesPerSecond
    }

    /// The ETA in words, and coarser the further out it is: a download that says "37
    /// seconds left" is claiming a precision it does not have, and one that says "1 minute"
    /// while it means 61 seconds is claiming worse.
    nonisolated static func etaText(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let whole = Int(seconds.rounded())
        if whole < 2 { return "About a second left" }
        if whole < 60 { return "\(whole) seconds left" }
        if whole < 90 { return "About a minute left" }
        if whole < 3600 { return "\(Int((Double(whole) / 60).rounded())) minutes left" }
        let hours = Int((Double(whole) / 3600).rounded())
        return hours <= 1 ? "About an hour left" : "\(hours) hours left"
    }

    /// A new rate sample folded into the running one. A third of the new reading, so a
    /// stalled packet does not throw the ETA and a real slowdown still gets through.
    nonisolated static func smoothed(previous: Double, bytes: Int64, over seconds: Double,
                                     weight: Double = 0.3) -> Double {
        guard seconds > 0, bytes >= 0 else { return previous }
        let sample = Double(bytes) / seconds
        return previous <= 0 ? sample : previous * (1 - weight) + sample * weight
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

        // --- Cancelling ---
        let cancelRoot = root.appendingPathComponent("cancel", isDirectory: true)
        try? fm.createDirectory(at: cancelRoot, withIntermediateDirectories: true)
        let halfFile = cancelRoot.appendingPathComponent("half.iso")
        try? Data(repeating: 0x41, count: 512).write(to: halfFile)
        let canceller = Downloads(profileID: ProfileManager.defaultID, directory: cancelRoot,
                                  sandboxed: true)
        var halfRec = Record(name: "half.iso", destination: halfFile, total: 4096,
                             received: 512, state: "paused")
        halfRec.reason = "Paused"
        let half = canceller.add(halfRec)
        canceller.cancel(half)
        assert("cancelling says so on the row", half.state == .failed(cancelledText))
        assert("a cancelled download is not offered for resume", canceller.canResume(half) == false)
        assert("cancelling deletes the half-written file", !fm.fileExists(atPath: halfFile.path))
        assert("a cancelled download survives a relaunch as cancelled",
               Downloads(profileID: ProfileManager.defaultID, directory: cancelRoot, sandboxed: true)
                   .items.first?.status == .failed)
        canceller.forget(half)
        assert("forgetting a row takes it out of the list", canceller.items.isEmpty)
        assert("forgetting a row is written down",
               Downloads(profileID: ProfileManager.defaultID, directory: cancelRoot, sandboxed: true)
                   .items.isEmpty)

        // --- Where downloads go (a scratch defaults suite; never the user's own) ---
        let suite = "vane.check.downloads.\(ProcessInfo.processInfo.processIdentifier)"
        if let scratch = UserDefaults(suiteName: suite) {
            defer { scratch.removePersistentDomain(forName: suite) }
            let id = ProfileManager.defaultID
            let other = UUID()
            assert("with nothing set, downloads go to the system folder",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            assert("nobody is asked where to save by default",
                   DownloadLocation.askEveryTime(for: id, defaults: scratch) == false)
            let picked = root.appendingPathComponent("picked", isDirectory: true)
            try? fm.createDirectory(at: picked, withIntermediateDirectories: true)
            DownloadLocation.setDirectory(picked, for: id, defaults: scratch)
            assert("a chosen folder is where downloads go",
                   DownloadLocation.directory(for: id, defaults: scratch).path == picked.path)
            assert("the choice is per profile, not global",
                   DownloadLocation.directory(for: other, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            try? fm.removeItem(at: picked)
            assert("a folder that has since been deleted falls back rather than failing",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            let notADirectory = root.appendingPathComponent("afile.txt")
            try? Data("x".utf8).write(to: notADirectory)
            DownloadLocation.setDirectory(notADirectory, for: id, defaults: scratch)
            assert("a file where a folder should be falls back too",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            DownloadLocation.setDirectory(nil, for: id, defaults: scratch)
            assert("clearing the choice goes back to the system folder",
                   scratch.string(forKey: DownloadLocation.directoryKey(id)) == nil)
            DownloadLocation.setAskEveryTime(true, for: id, defaults: scratch)
            assert("asking every time is remembered",
                   DownloadLocation.askEveryTime(for: id, defaults: scratch))
            assert("...for that profile only",
                   DownloadLocation.askEveryTime(for: other, defaults: scratch) == false)
            assert("the system folder is drawn as Downloads",
                   DownloadLocation.label(DownloadLocation.systemDownloads) == "Downloads")
            assert("any other folder is drawn by its own name",
                   DownloadLocation.label(URL(fileURLWithPath: "/Users/x/Desktop/Files")) == "Files")
        } else {
            assert("scratch defaults suite is available", false)
        }

        // --- Sizes, in the words the row draws ---
        assert("a small file is counted in bytes", byteText(512) == "512 bytes")
        assert("one byte is not one bytes", byteText(1) == "1 byte")
        assert("nothing yet reads as zero", byteText(0) == "0 bytes")
        assert("a kilobyte is decimal, like the Finder's", byteText(1000) == "1.0 KB")
        assert("999 bytes is still bytes", byteText(999) == "999 bytes")
        assert("a megabyte reads as one", byteText(1_500_000) == "1.5 MB")
        assert("a big number drops the decimal", byteText(12_345_678) == "12 MB")
        assert("a gigabyte reads as one", byteText(2_400_000_000) == "2.4 GB")
        assert("progress reads as one size out of another",
               sizeText(received: 1_500_000, total: 3_000_000) == "1.5 MB of 3.0 MB")
        assert("a finished download is just its size",
               sizeText(received: 3_000_000, total: 3_000_000, done: true) == "3.0 MB")
        assert("a server that never said how big shows what has arrived",
               sizeText(received: 1_500_000, total: 0) == "1.5 MB")
        assert("a download past its stated size shows what has arrived",
               sizeText(received: 3_100_000, total: 3_000_000) == "3.1 MB")

        // --- Time remaining ---
        assert("half a file at a megabyte a second is a second and a half",
               secondsRemaining(received: 500_000, total: 2_000_000, bytesPerSecond: 1_000_000) == 1.5)
        assert("an unknown size has no ETA",
               secondsRemaining(received: 500_000, total: 0, bytesPerSecond: 1_000_000) == nil)
        assert("a stalled transfer has no ETA",
               secondsRemaining(received: 1, total: 100, bytesPerSecond: 0) == nil)
        assert("no ETA prints nothing at all", etaText(seconds: nil) == "")
        assert("under two seconds is about a second", etaText(seconds: 1.4) == "About a second left")
        assert("seconds are seconds", etaText(seconds: 42) == "42 seconds left")
        assert("just over a minute is about a minute", etaText(seconds: 61) == "About a minute left")
        assert("minutes are minutes", etaText(seconds: 200) == "3 minutes left")
        assert("just under an hour is still minutes", etaText(seconds: 3500) == "58 minutes left")
        assert("just over an hour is about an hour", etaText(seconds: 3700) == "About an hour left")
        assert("hours are hours", etaText(seconds: 7300) == "2 hours left")

        // --- The rate the ETA is built on ---
        assert("the first sample is taken as it is",
               smoothed(previous: 0, bytes: 1000, over: 1) == 1000)
        assert("a later sample only moves the rate part of the way",
               smoothed(previous: 1000, bytes: 2000, over: 1) == 1300)
        assert("a zero-length interval cannot divide by it",
               smoothed(previous: 1000, bytes: 500, over: 0) == 1000)
        assert("a stalled sample drags the rate down without zeroing it",
               smoothed(previous: 1000, bytes: 0, over: 1) == 700)

        return out
    }

    private static var defaultProfile: UUID { ProfileManager.defaultID }
}

// MARK: - Where downloads go

/// The download destination, per profile — Arc keeps it in Profiles, next to the search
/// engine and the archive cadence, because a work profile and a personal one do not file
/// their downloads in the same place.
///
/// ponytail: a path string in UserDefaults, not a security-scoped bookmark. Vane is not
/// sandboxed, so a path is the whole of it; a folder the user later deletes falls back to
/// ~/Downloads rather than failing the download.
@MainActor enum DownloadLocation {
    /// The system folder, and what an unset preference means.
    nonisolated static var systemDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    nonisolated static func directoryKey(_ id: UUID) -> String {
        ProfileManager.defaultsKey("downloadDirectory", id)
    }
    nonisolated static func askKey(_ id: UUID) -> String {
        ProfileManager.defaultsKey("downloadAskEveryTime", id)
    }

    /// Where this profile files its downloads. A stored folder that has since been deleted
    /// or renamed is not an error the user should meet as a failed download.
    static func directory(for id: UUID, defaults: UserDefaults = .vane,
                          fm: FileManager = .default) -> URL {
        guard let path = defaults.string(forKey: directoryKey(id)), !path.isEmpty else {
            return systemDownloads
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return systemDownloads
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Nil resets to the system folder rather than storing an empty path.
    static func setDirectory(_ url: URL?, for id: UUID, defaults: UserDefaults = .vane) {
        guard let url else { return defaults.removeObject(forKey: directoryKey(id)) }
        defaults.set(url.path, forKey: directoryKey(id))
    }

    static func askEveryTime(for id: UUID, defaults: UserDefaults = .vane) -> Bool {
        defaults.bool(forKey: askKey(id))
    }

    static func setAskEveryTime(_ on: Bool, for id: UUID, defaults: UserDefaults = .vane) {
        defaults.set(on, forKey: askKey(id))
    }

    /// The folder picker behind the settings row.
    static func choose(for id: UUID, current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.prompt = "Choose"
        panel.message = "Where should downloads be saved?"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setDirectory(url, for: id)
        return url
    }

    /// The folder's name, as the settings row draws it: the last component, or "Downloads"
    /// for the system folder wherever it is and whatever the user has renamed it to.
    nonisolated static func label(_ url: URL) -> String {
        url.path == systemDownloads.path ? "Downloads" : url.lastPathComponent
    }
}
