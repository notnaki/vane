import AppKit
import WebKit
import CryptoKit

/// ponytail: WKDownload still does the transfer, the resume data and the progress
/// reporting. What it does not do is remember anything across a launch, so this file is
/// the destination policy, a JSON list on disk per profile, and the pause/resume plumbing.
@MainActor final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {

    /// Resolves per profile, exactly like `Store.shared`, and by the same suffix rule — the
    /// default profile's file is plain `downloads.json`.
    static var shared: Downloads { manager(for: ProfileManager.shared.active.id) }

    fileprivate static var cache: [UUID: Downloads] = [:]

    static func manager(for id: UUID) -> Downloads {
        if let hit = cache[id] { return hit }
        let fresh = Downloads(profileID: id, directory: Store.directory)
        cache[id] = fresh
        return fresh
    }

    /// Drop the list and both on-disk files. Call this when a profile is deleted.
    static func forget(_ id: UUID, in dir: URL = Store.directory) {
        if let manager = cache[id] {
            manager.invalidated = true
            for download in manager.pendingDownloads.values {
                download.delegate = nil
                download.cancel { _ in }
            }
            manager.pendingDownloads = [:]
            manager.privateSources = [:]
            manager.origins = [:]
            for item in manager.items {
                if item.status.isLive { manager.cancel(item) }
                item.operation = UUID()
                ScopedPaths.releaseBookmark(owner: item.scopeOwner)
            }
            manager.items = []
            manager.retryOrigins = [:]
        }
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
    /// Nil for ordinary isolated checks; production uses .vane and a focused check can
    /// supply a throwaway suite to exercise preference migration.
    private let locationDefaults: UserDefaults?
    private var privateResumeData: [UUID: Data] = [:]
    private var invalidated = false
    private var pendingDownloads: [ObjectIdentifier: WKDownload] = [:]
    /// Reservations span profiles until WebKit creates a file that the filesystem can
    /// protect. They never create placeholder files, which WKDownload rejects.
    private static var pendingDestinations: [UUID: URL] = [:]

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
         sandboxed: Bool = false,
         locationDefaults: UserDefaults? = nil) {
        self.profileID = profileID
        self.directory = directory
        self.sandboxed = sandboxed
        self.locationDefaults = profileID == Profile.incognito.id ? nil
            : locationDefaults ?? (sandboxed ? nil : .vane)
        super.init()
        // History, resumed transfers and Finder actions inspect saved destination URLs
        // before the next download asks for a destination. Reopen the folder's sandbox
        // grant before `load()` decides that a finished file has gone missing.
        if let locationDefaults = self.locationDefaults {
            _ = DownloadLocation.directory(for: profileID, defaults: locationDefaults)
        }
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
        /// Retained across launches so downloads from different profiles have one order.
        let started: Date
        /// Distinct per loaded instance, since a check or another manager can open the
        /// same record ID while this manager still holds its grant.
        fileprivate let scopeOwner = UUID()
        /// nil for a restored row and for anything interrupted — the WKDownload died with
        /// the process, or with the connection, that owned it.
        private(set) var download: WKDownload?
        @Published var name: String
        /// Destination on disk. Kept spelled `url` because UI.swift and `reveal` read it.
        @Published var url: URL?
        @Published var source: URL?
        fileprivate var sourceMethod: String?
        @Published fileprivate var retryPending = false
        fileprivate weak var sourceWeb: WKWebView?
        fileprivate var privateStore: WKWebsiteDataStore?
        fileprivate var privateResumer: WKWebView?
        fileprivate var resumePending = false
        fileprivate var partialIdentity: FileIdentity?
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
        fileprivate var resumeChecksum: String?
        /// Grant for the destination folder, or for the file chosen in a Save panel.
        /// The profile may choose a different folder before this row is opened or resumed.
        fileprivate var destinationBookmark: Data?
        /// Save panels grant the selected file, not its containing directory.
        fileprivate var destinationBookmarkIsFile: Bool?
        /// Distinguishes "the user pressed pause" from "the network fell over" — the two
        /// need different words when the resume data turns out not to exist.
        fileprivate var pausedByUser = false
        fileprivate var operation = UUID()
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
            self.started = .now
            self.name = name
            watch(download)
        }

        fileprivate init(record: Record) {
            id = record.id
            started = record.started ?? record.completed ?? .distantPast
            name = record.name
            url = record.destination
            source = record.source
            sourceMethod = record.sourceMethod
            partialIdentity = record.partialIdentity
            total = record.total
            received = record.received
            completed = record.completed
            resumeFile = record.resumeFile
            resumeChecksum = record.resumeChecksum
            destinationBookmark = record.destinationBookmark
            destinationBookmarkIsFile = record.destinationBookmarkIsFile
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
                          completed: completed, resumeFile: resumeFile,
                          destinationBookmark: destinationBookmark,
                          destinationBookmarkIsFile: destinationBookmarkIsFile,
                          started: started, sourceMethod: sourceMethod, partialIdentity: partialIdentity,
                          resumeChecksum: resumeChecksum)
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
    /// completion date, per the brief; plus the name of the resume blob in `resumeDir`
    /// and a folder bookmark so this row remains accessible after the profile moves on.
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
        var destinationBookmark: Data?
        var destinationBookmarkIsFile: Bool?
        var started: Date?
        var sourceMethod: String?
        var partialIdentity: FileIdentity?
        var resumeChecksum: String?
    }

    struct FileIdentity: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        nonisolated static func at(_ url: URL) -> FileIdentity? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
        }
    }

    static let missingText = "The file was moved or deleted."

    /// A path existing is insufficient: a folder, unreadable file, or truncated finished
    /// file cannot be opened as a successful download.
    nonisolated static func validFileSize(_ url: URL, expected: Int64? = nil) -> Int64? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: url.path),
              expected == nil || Int64(size) == expected else { return nil }
        return Int64(size)
    }


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
        guard profileID != Profile.incognito.id else { return }
        guard let data = try? Data(contentsOf: Self.listURL(for: profileID, in: directory)),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        var upgraded = false
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
            let item = Item(record: r)
            // Older indexes have no row bookmark. While the current folder's grant is
            // still available, give those rows their own copy before the user changes it.
            if item.destinationBookmark == nil, item.destinationBookmarkIsFile != true,
               let target = item.url,
               let locationDefaults,
               let grant = DownloadLocation.bookmark(for: target, profileID: profileID,
                                                     defaults: locationDefaults) {
                item.destinationBookmark = grant
                upgraded = true
            }
            let destination = restoredDestination(item)
            if item.status == .paused {
                if item.destinationBookmark != nil && destination == nil {
                    item.state = .failed("Download folder unavailable. Reconnect it to resume.")
                } else if let why = resumeProblem(item) {
                    item.status = .failed
                    item.state = .failed(why)
                    deleteResume(item)
                    removePartial(item)
                    upgraded = true
                }
            }
            if r.state == "done", let d = destination,
               Self.validFileSize(d) != nil { return item }
            if r.state == "done" {
                item.status = .missing
                item.state = .failed(Self.missingText)
            }
            return item
        }
        for i in items {
            i.onProgress = { [weak self, weak i] in
                if let i { self?.capturePartialIdentity(i) }
                self?.throttledSave()
            }
        }
        if backfillPendingRows() {
            upgraded = true
            for item in items where item.status == .missing {
                if let destination = restoredDestination(item),
                   Self.validFileSize(destination) != nil {
                    item.status = .done
                    item.state = .done
                }
            }
        }
        if upgraded { save() }
    }

    /// A previous preference bookmark can be kept here when its volume is absent and
    /// even its path cannot be resolved during a Settings change. Try again on load and
    /// whenever the downloads list refreshes after a volume returns.
    private func backfillPendingRows() -> Bool {
        guard let defaults = locationDefaults else { return false }
        let key = DownloadLocation.pendingDirectoryKey(profileID)
        let pending = (defaults.array(forKey: key) as? [Data]) ?? []
        var unresolved: [Data] = []
        var changed = false
        for grant in pending {
            guard let folder = ScopedPaths.bookmarkedURL(grant) else {
                unresolved.append(grant)
                continue
            }
            let selected = folder.resolvingSymlinksInPath().path
            var attached = items.contains { $0.destinationBookmark == grant }
            for item in items where item.destinationBookmark == nil
                && item.destinationBookmarkIsFile != true {
                guard item.url?.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == selected else { continue }
                item.destinationBookmark = grant
                changed = true
                attached = true
            }
            if !attached { unresolved.append(grant) }
        }
        if unresolved.count != pending.count {
            if unresolved.isEmpty { defaults.removeObject(forKey: key) }
            else { defaults.set(unresolved, forKey: key) }
        }
        return changed
    }

    /// A folder may have been inaccessible when this manager loaded. Once the user
    /// chooses it again, repair the rows already in memory and persist their grants.
    fileprivate static func backfillCachedRows(for id: UUID, folder: URL, grant: Data) {
        guard let manager = cache[id] else { return }
        var changed = false
        let selected = folder.resolvingSymlinksInPath().path
        for item in manager.items where item.destinationBookmark == nil
            && item.destinationBookmarkIsFile != true {
            guard item.url?.deletingLastPathComponent().resolvingSymlinksInPath().path == selected else {
                continue
            }
            item.destinationBookmark = grant
            changed = true
        }
        if changed {
            manager.refreshMissing()
            manager.save()
        }
    }

    /// Settings can be opened before the downloads manager. Upgrade old JSON rows while
    /// the previous folder's extension is still active, before replacing that choice.
    fileprivate static func backfillPersistedRows(for id: UUID, in directory: URL,
                                                  folder: URL, grant: Data) {
        let list = listURL(for: id, in: directory)
        guard let data = try? Data(contentsOf: list),
              var records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        let selected = folder.resolvingSymlinksInPath().path
        var changed = false
        for index in records.indices where records[index].destinationBookmark == nil
            && records[index].destinationBookmarkIsFile != true {
            guard records[index].destination?.deletingLastPathComponent()
                .resolvingSymlinksInPath().path == selected else { continue }
            records[index].destinationBookmark = grant
            changed = true
        }
        if changed, let encoded = try? JSONEncoder().encode(records) {
            try? encoded.write(to: list, options: .atomic)
        }
    }

    /// Trims to the cap and writes the index. Called on every state change and, throttled,
    /// while bytes are arriving.
    func save() {
        guard !invalidated else { return }
        lastSave = .now
        var keep: [Item] = []
        var evicted: [Item] = []
        var finished = 0
        for i in items {
            if i.status.isLive { keep.append(i); continue }
            finished += 1
            if finished <= Self.historyLimit { keep.append(i) } else { evicted.append(i) }
        }
        for e in evicted {
            deleteResume(e)
            ScopedPaths.releaseBookmark(owner: e.scopeOwner)
        }
        if !evicted.isEmpty { items = keep }
        guard profileID != Profile.incognito.id else { return }
        guard let data = try? JSONEncoder().encode(keep.map(\.record)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.listURL(for: profileID, in: directory), options: .atomic)
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
        var record = record
        if record.started == nil { record.started = record.completed ?? .now }
        let item = Item(record: record)
        if item.partialIdentity == nil, item.received > 0, item.status.isLive, let url = item.url {
            item.partialIdentity = FileIdentity.at(url)
        }
        item.onProgress = { [weak self, weak item] in
            if let item { self?.capturePartialIdentity(item) }
            self?.throttledSave()
        }
        items.insert(item, at: 0)
        save()
        return item
    }

    /// Clears the history. Running and paused rows stay: the list is the only handle on
    /// them, and "clear" should not silently throw away a resumable transfer.
    func clear() {
        for i in items where !i.status.isLive {
            deleteResume(i)
            ScopedPaths.releaseBookmark(owner: i.scopeOwner)
        }
        items = items.filter(\.status.isLive)
        save()
    }

    /// Re-checks every finished row against the filesystem. Cheap enough to call whenever
    /// the downloads popover opens.
    func refreshMissing() {
        var changed = backfillPendingRows()
        for i in items where i.status == .done || i.status == .missing {
            let there = restoredDestination(i)
                .map { Self.validFileSize($0) != nil } ?? false
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

    /// Reopen the grant attached to this row, then follow the bookmark if the folder was
    /// moved. A temporarily disconnected volume returns nil without discarding the grant.
    private func restoredDestination(_ item: Item) -> URL? {
        guard let saved = item.url else { return nil }
        guard let bookmark = item.destinationBookmark else {
            return item.destinationBookmarkIsFile == true ? nil : saved
        }
        guard let granted = ScopedPaths.accessBookmark(bookmark, owner: item.scopeOwner) else { return nil }
        if item.destinationBookmarkIsFile == true {
            if item.url != granted { item.url = granted }
            return granted
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: granted.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let resolved = granted.appendingPathComponent(saved.lastPathComponent)
        if item.url != resolved { item.url = resolved }
        return resolved
    }

    private var saveAsDownloads: [ObjectIdentifier: String] = [:]
    private var privateSources: [ObjectIdentifier: WKWebsiteDataStore] = [:]
    private struct Origin { weak var web: WKWebView?; weak var window: NSWindow? }
    private var origins: [ObjectIdentifier: Origin] = [:]

    func attach(_ download: WKDownload, alwaysAsk: Bool = false, suggestedFilename: String? = nil,
                from webView: WKWebView? = nil, in window: NSWindow? = nil) {
        guard !invalidated else { download.cancel { _ in }; return }
        pendingDownloads[ObjectIdentifier(download)] = download
        if let source = webView ?? download.webView { origins[ObjectIdentifier(download)] = Origin(web: source, window: window ?? source.window) }
        if profileID == Profile.incognito.id {
            privateSources[ObjectIdentifier(download)] = (webView ?? download.webView)?.configuration.websiteDataStore
        }
        if alwaysAsk { saveAsDownloads[ObjectIdentifier(download)] = suggestedFilename ?? "" }
        download.delegate = self
    }

    /// A server filename wins over the anchor's download attribute. Otherwise preserve
    /// that attribute, including its extension, rather than the URL's endpoint name.
    nonisolated static func saveAsFilename(anchor: String?, server: String, disposition: String?) -> String {
        if disposition?.range(of: #"(?:^|;)\s*filename\*?\s*="#,
                              options: [.regularExpression, .caseInsensitive]) != nil { return server }
        guard let anchor, !anchor.isEmpty else { return server }
        let safe = anchor.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        return safe == "." || safe == ".." ? server : safe
    }

    /// Never overwrite: "report.pdf", then "report 2.pdf". Unchanged behaviour, just lifted
    /// out of the delegate so `check()` can prove it against a temp directory instead of
    /// the user's real ~/Downloads.
    nonisolated static func uniqueDestination(in dir: URL, suggested: String,
                                              fm: FileManager = .default, reserved: [URL] = []) -> URL {
        let safe = suggested.replacingOccurrences(of: "/", with: ":")
        var target = dir.appendingPathComponent(safe.isEmpty ? "download" : safe)
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        let occupied = Set(reserved.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var n = 2
        while fm.fileExists(atPath: target.path)
            || occupied.contains(target.standardizedFileURL.resolvingSymlinksInPath().path) {
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
        let pending = pendingDownloads[ObjectIdentifier(download)]
        guard acceptsRetryOrigin(download),
              pending != nil || resuming[ObjectIdentifier(download)] != nil else {
            completionHandler(nil)
            return
        }
        // A resumed transfer must land back on its own partial file. Uniquifying here would
        // hand WebKit an empty "report 2.pdf" and restart from zero — exactly the silent
        // failure the brief forbids.
        if let entry = resuming.removeValue(forKey: ObjectIdentifier(download)) {
            guard items.contains(where: { $0 === entry }), entry.download === download,
                  entry.status.isLive else { completionHandler(nil); return }
            save()
            completionHandler(entry.url)
            return
        }
        let privateStore = privateSources.removeValue(forKey: ObjectIdentifier(download))
        let origin = origins.removeValue(forKey: ObjectIdentifier(download))
        var target = Self.uniqueDestination(in: destinationDirectory, suggested: suggestedFilename,
                                            reserved: Array(Self.pendingDestinations.values))
        let anchorFilename = saveAsDownloads.removeValue(forKey: ObjectIdentifier(download))
        let chosenByPanel = anchorFilename != nil || DownloadLocation.askEveryTime(for: profileID)
        if chosenByPanel {
            let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
            let name = Self.saveAsFilename(anchor: anchorFilename, server: suggestedFilename, disposition: disposition)
            guard let chosen = askWhereToSave(suggested: name,
                                              in: destinationDirectory) else {
                completionHandler(nil)      // cancelled: no file, and no row either
                return
            }
            target = chosen
        }
        guard acceptsRetryOrigin(download), pendingDownloads[ObjectIdentifier(download)] != nil else {
            completionHandler(nil)
            return
        }
        pendingDownloads.removeValue(forKey: ObjectIdentifier(download))
        let entry = Item(download, name: target.lastPathComponent)
        entry.url = target
        entry.destinationBookmarkIsFile = chosenByPanel ? true : nil
        entry.destinationBookmark = DownloadLocation.bookmark(for: target, profileID: profileID,
                                                             selectedFile: chosenByPanel)
        entry.source = download.originalRequest?.url ?? response.url
        entry.sourceMethod = download.originalRequest?.httpMethod
        entry.sourceWeb = origin?.web ?? download.webView
        if profileID == Profile.incognito.id {
            entry.privateStore = privateStore ?? download.webView?.configuration.websiteDataStore
        }
        entry.total = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        entry.onProgress = { [weak self, weak entry] in
            if let entry {
                self?.captureFileGrant(entry)
                self?.capturePartialIdentity(entry)
            }
            self?.throttledSave()
        }
        items.insert(entry, at: 0)
        Self.pendingDestinations[entry.scopeOwner] = target
        save()
        completionHandler(target)
        if let window = origin?.window {
            NotificationCenter.default.post(name: DownloadFeedback.started,
                object: DownloadFeedback.Start(name: entry.name, profileID: profileID, window: window))
        }
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
        resuming.removeValue(forKey: ObjectIdentifier(download))
        retryOrigins.removeValue(forKey: ObjectIdentifier(download))?.item.retryPending = false
        guard let i = item(for: download) else { return }
        Self.pendingDestinations[i.scopeOwner] = nil
        captureFileGrant(i)
        guard let destination = restoredDestination(i),
              let size = Self.validFileSize(destination, expected: i.total > 0 ? i.total : nil) else {
            i.unwatch()
            finish(i, error: "The downloaded file is unavailable or unreadable. Retry the download.", resumeData: nil)
            return
        }
        TidyDownloads.tidy(download, in: self)      // before unwatch() nils out item.download
        i.unwatch()
        i.state = .done
        i.status = .done
        i.fraction = 1
        // The file on disk is the only byte count that cannot be wrong.
        i.received = size
        i.total = size
        i.completed = .now
        i.partialIdentity = nil
        deleteResume(i)
        save()
        InteractionSounds.play(.complete)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pendingDownloads.removeValue(forKey: ObjectIdentifier(download))
        saveAsDownloads.removeValue(forKey: ObjectIdentifier(download))
        privateSources.removeValue(forKey: ObjectIdentifier(download))
        origins.removeValue(forKey: ObjectIdentifier(download))
        resuming.removeValue(forKey: ObjectIdentifier(download))
        retryOrigins.removeValue(forKey: ObjectIdentifier(download))?.item.retryPending = false
        guard let i = item(for: download) else { return }
        i.unwatch()
        finish(i, error: error.localizedDescription, resumeData: resumeData)
    }

    /// One place decides what an interrupted transfer becomes: resumable if WebKit handed
    /// back resume data, dead otherwise.
    private func finish(_ i: Item, error: String, resumeData: Data?) {
        Self.pendingDestinations[i.scopeOwner] = nil
        captureFileGrant(i)
        if let data = resumeData, !data.isEmpty, writeResume(data, for: i) {
            i.status = .paused
            i.state = .failed(i.pausedByUser ? "Paused" : "Interrupted — \(error). Resume available.")
        } else {
            deleteResume(i)
            i.status = .failed
            removePartial(i)
            i.state = .failed(resumeData?.isEmpty == false
                              ? "Could not save resume data. Retry starts from the beginning."
                              : i.pausedByUser
                                ? "WebKit did not provide resume data. Retry starts from the beginning."
                                : "\(error). Retry starts from the beginning.")
        }
        i.pausedByUser = false
        save()
    }

    /// A Save panel may authorize a new path before the file exists. Capture its file
    /// bookmark as soon as WebKit creates it, including before a paused transfer is saved.
    private func captureFileGrant(_ item: Item) {
        guard item.destinationBookmarkIsFile == true, item.destinationBookmark == nil,
              let url = item.url, FileManager.default.fileExists(atPath: url.path) else { return }
        item.destinationBookmark = ScopedPaths.bookmarkForLater(url)
    }

    private func capturePartialIdentity(_ item: Item) {
        // A chosen path (including progress.fileURL) precedes WebKit's exclusive file
        // creation. Wait for written bytes; polling an empty path can adopt a user file
        // that WebKit subsequently rejects. Preserve unverified zero-byte destinations.
        guard item.partialIdentity == nil, item.received > 0, let url = item.url else { return }
        item.partialIdentity = FileIdentity.at(url)
        if item.partialIdentity != nil { Self.pendingDestinations[item.scopeOwner] = nil }
    }

    private func removePartial(_ item: Item) {
        guard let identity = item.partialIdentity, let url = restoredDestination(item),
              FileIdentity.at(url) == identity else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct RetryOrigin {
        let item: Item
        let operation: UUID
    }
    private var retryOrigins: [ObjectIdentifier: RetryOrigin] = [:]

    private func acceptsRetryOrigin(_ download: WKDownload) -> Bool {
        guard !invalidated else { return false }
        guard let origin = retryOrigins[ObjectIdentifier(download)] else { return true }
        return origin.item.retryPending && origin.item.operation == origin.operation
            && items.contains(where: { $0 === origin.item })
    }

    func canRetry(_ item: Item) -> Bool {
        guard !invalidated, items.contains(where: { $0 === item }), !item.retryPending, !item.resumePending,
              item.download == nil, item.completed == nil,
              item.status == .failed || (item.status == .paused && !canResume(item)),
              let source = item.source, ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
              item.sourceMethod == "GET",
              profileID != Profile.incognito.id || item.sourceWeb != nil else { return false }
        return true
    }

    /// Retry is a new WebKit request and a new row. It uses today's folder choice (or a
    /// new Save panel for a file-specific grant), and never hands WebKit an existing file.
    @discardableResult
    func retry(_ item: Item) -> Bool {
        guard canRetry(item), let source = item.source else { return false }
        item.operation = UUID()
        let operation = item.operation
        item.retryPending = true
        deleteResume(item)
        removePartial(item)
        resumeWebView(for: item).startDownload(using: URLRequest(url: source)) { [weak self, weak item] download in
            guard let self, let item, !self.invalidated, item.retryPending,
                  item.operation == operation, self.items.contains(where: { $0 === item }) else {
                download.cancel { _ in }
                return
            }
            self.retryOrigins[ObjectIdentifier(download)] = RetryOrigin(item: item, operation: operation)
            self.attach(download, alwaysAsk: item.destinationBookmarkIsFile == true,
                        suggestedFilename: item.name, from: self.resumeWebView(for: item))
        }
        return true
    }

    // MARK: Pause and resume

    /// Items awaiting their `decideDestinationUsing` callback after a resume, keyed by the
    /// fresh WKDownload WebKit handed back.
    private var resuming: [ObjectIdentifier: Item] = [:]

    func pause(_ item: Item) {
        guard items.contains(where: { $0 === item }), item.status == .running else { return }
        if item.resumePending {
            item.pausedByUser = true
            item.status = .paused
            item.state = .failed("Pausing…")
            save()
            return
        }
        guard let d = item.download else { return }
        item.operation = UUID()
        let operation = item.operation
        item.pausedByUser = true
        item.status = .paused
        item.state = .failed("Pausing…")
        d.cancel { [weak self] data in
            guard let self, item.operation == operation,
                  self.items.contains(where: { $0 === item }), item.download === d else { return }
            self.resuming.removeValue(forKey: ObjectIdentifier(d))
            self.retryOrigins.removeValue(forKey: ObjectIdentifier(d))?.item.retryPending = false
            d.delegate = nil
            item.unwatch()
            self.finish(item, error: "Paused", resumeData: data)
        }
    }

    /// Anything the user could still finish: paused, or interrupted with a blob on disk.
    func canResume(_ item: Item) -> Bool {
        !invalidated && items.contains(where: { $0 === item }) && item.status == .paused
            && item.download == nil && !item.resumePending && resumeProblem(item) == nil
    }

    private func resumeProblem(_ item: Item) -> String? {
        if let identity = item.partialIdentity, let destination = restoredDestination(item),
           FileIdentity.at(destination) != identity {
            return "Cannot resume: the partial file was moved or replaced. Retry starts from the beginning."
        }
        let data = readResume(item)
        if let expected = item.resumeChecksum, let data,
           Self.checksum(data) != expected {
            return "Cannot resume: the saved resume data is damaged. Retry starts from the beginning."
        }
        return Self.resumeBlocker(destination: restoredDestination(item), resumeData: data)
    }

    nonisolated private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Why a resume cannot work, or nil if it can. Pure — the record plus the filesystem,
    /// no network — so `check()` can prove the staleness rules offline.
    ///
    /// Reject damaged binary property lists without decoding private WebKit fields.
    /// A structurally intact blob is still only an attempt; WebKit decides whether the
    /// server and its own partial-response bookkeeping support continuation.
    nonisolated static func resumeBlocker(destination: URL?, resumeData: Data?,
                                          fm: FileManager = .default) -> String? {
        guard let data = resumeData, !data.isEmpty else {
            return "Cannot resume: the server did not offer a way to continue this download."
        }
        guard data.count > 8, data.prefix(8) == Data("bplist00".utf8),
              (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            return "Cannot resume: the saved resume data is damaged."
        }
        guard let destination else { return "Cannot resume: this download has no destination." }
        guard (try? fm.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeRegular,
              fm.isReadableFile(atPath: destination.path) else {
            return "Cannot resume: the partial file was moved or deleted."
        }
        return nil
    }

    /// Restarts a paused or interrupted transfer. Returns false — and says why on the row —
    /// when it cannot, rather than starting over from zero.
    @discardableResult
    func resume(_ item: Item) -> Bool {
        guard !invalidated, items.contains(where: { $0 === item }), item.status == .paused,
              item.download == nil, !item.resumePending else { return false }
        if item.destinationBookmark != nil && restoredDestination(item) == nil {
            item.status = .paused
            item.state = .failed("Download folder unavailable. Reconnect it to resume.")
            save()
            return false
        }
        let data = readResume(item)
        if let why = resumeProblem(item) {
            deleteResume(item)
            item.status = .failed
            item.state = .failed(why)
            save()
            return false
        }
        item.operation = UUID()
        let operation = item.operation
        item.status = .running
        item.state = .running
        item.pausedByUser = false
        save()
        item.resumePending = true
        resumeWebView(for: item).resumeDownload(fromResumeData: data!) { [weak self] d in
            item.resumePending = false
            guard let self, item.operation == operation, item.status.isLive,
                  self.items.contains(where: { $0 === item }) else {
                d.cancel { [weak self] _ in self?.removePartial(item) }
                return
            }
            self.resuming[ObjectIdentifier(d)] = item
            item.watch(d)
            d.delegate = self
            if item.pausedByUser {
                item.status = .running
                self.pause(item)
            }
        }
        return true
    }

    /// Quit is the common interruption, and `cancel` hands back its resume data
    /// asynchronously — after the process would already be gone. So spin the main runloop
    /// for up to two seconds. Ugly, and the only difference between a resumable download
    /// and a dead one on ⌘Q.
    func pauseAll() {
        let pending = items.filter { $0.status == .running || ($0.pausedByUser && $0.status == .paused) }
        guard !pending.isEmpty else { return }
        for i in pending where i.status == .running { pause(i) }
        let deadline = Date.now.addingTimeInterval(2)
        while Date.now < deadline && pending.contains(where: { ($0.download != nil || $0.resumePending) && $0.pausedByUser }) {
            RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }
        save()
    }

    /// A private WKWebView purely to own `resumeDownload`. It is not displayed; the
    /// profile's data store is what carries the cookies the range request needs.
    private func resumeWebView(for item: Item) -> WKWebView {
        if let source = item.sourceWeb { return source }
        guard profileID == Profile.incognito.id, let store = item.privateStore else { return resumer }
        if let web = item.privateResumer { return web }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: configuration)
        item.privateResumer = web
        return web
    }

    private lazy var resumer: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = ProfileManager.dataStore(for: profileID)
        return WKWebView(frame: .zero, configuration: cfg)
    }()

    private func resumeURL(_ item: Item) -> URL {
        Self.resumeDir(for: profileID, in: directory)
            .appendingPathComponent("\(item.id.uuidString).resume")
    }

    @discardableResult
    private func writeResume(_ data: Data, for item: Item) -> Bool {
        if profileID == Profile.incognito.id {
            privateResumeData[item.id] = data
            item.resumeFile = "\(item.id.uuidString).resume"
            item.resumeChecksum = Self.checksum(data)
            return true
        }
        let dir = Self.resumeDir(for: profileID, in: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: resumeURL(item), options: .atomic)) != nil else { return false }
        item.resumeFile = resumeURL(item).lastPathComponent
        item.resumeChecksum = Self.checksum(data)
        return true
    }

    private func readResume(_ item: Item) -> Data? {
        if profileID == Profile.incognito.id { return privateResumeData[item.id] }
        return item.resumeFile == nil ? nil : try? Data(contentsOf: resumeURL(item))
    }

    private func deleteResume(_ item: Item) {
        if profileID == Profile.incognito.id { privateResumeData[item.id] = nil }
        else { try? FileManager.default.removeItem(at: resumeURL(item)) }
        item.resumeFile = nil
        item.resumeChecksum = nil
    }

    // MARK: Cancel

    /// Stop a transfer for good and take the half-written file with it. Distinct from
    /// `pause`, which keeps both the partial file and the resume data on purpose.
    func cancel(_ item: Item) {
        guard items.contains(where: { $0 === item }), item.status.isLive || item.retryPending else { return }
        item.operation = UUID()
        item.pausedByUser = false
        item.retryPending = false
        for (key, origin) in retryOrigins.filter({ $0.value.item === item }) {
            retryOrigins[key] = nil
            if let pending = pendingDownloads.removeValue(forKey: key) {
                saveAsDownloads[key] = nil
                privateSources[key] = nil
                origins[key] = nil
                pending.delegate = nil
                pending.cancel { _ in }
            } else if let child = items.first(where: { $0.download.map(ObjectIdentifier.init) == key }) {
                cancel(child)
            }
        }
        if let d = item.download {
            resuming.removeValue(forKey: ObjectIdentifier(d))
            retryOrigins.removeValue(forKey: ObjectIdentifier(d))?.item.retryPending = false
            d.delegate = nil
            d.cancel { [self] _ in
                removePartial(item)
                Self.pendingDestinations[item.scopeOwner] = nil
                if !items.contains(where: { $0 === item }) {
                    ScopedPaths.releaseBookmark(owner: item.scopeOwner)
                }
            }
            item.unwatch()
        }
        deleteResume(item)
        if !item.resumePending { removePartial(item) }
        item.status = .failed
        item.state = .failed(Self.cancelledText)
        item.bytesPerSecond = 0
        save()
    }

    static let cancelledText = "Cancelled"

    /// Takes a row out of the list. The file on disk is left alone: the Library is a list
    /// of what happened, and forgetting an entry is not the same as deleting a download.
    func forget(_ item: Item) {
        guard items.contains(where: { $0 === item }) else { return }
        if item.status.isLive || item.retryPending { cancel(item) }
        item.operation = UUID()
        deleteResume(item)
        ScopedPaths.releaseBookmark(owner: item.scopeOwner)
        items.removeAll { $0 === item }
        save()
    }

    // MARK: Finder

    private func markMissing(_ item: Item) {
        item.status = .missing
        item.state = .failed(Self.missingText)
        save()
    }

    /// Clicking a finished download opens it, the way it does in Arc's Library.
    func open(_ item: Item) {
        guard let url = restoredDestination(item),
              FileManager.default.fileExists(atPath: url.path) else {
            markMissing(item)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: Item) {
        // The row may have been finished weeks ago; do not open Finder onto nothing.
        guard let url = restoredDestination(item),
              FileManager.default.fileExists(atPath: url.path) else {
            markMissing(item)
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
        let incognito = Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true)
        incognito.add(Record(name: "private.zip", destination: file,
                             source: URL(string: "https://private.example/file"), state: "done"))
        assert("incognito downloads remain available during the session", incognito.items.count == 1)
        assert("incognito download records never create an index",
               !fm.fileExists(atPath: listURL(for: Profile.incognito.id, in: root).path))
        if let item = incognito.items.first {
            let data = Data("private resume fixture".utf8)
            incognito.writeResume(data, for: item)
            assert("incognito downloads can resume from memory", incognito.readResume(item) == data)
            assert("incognito resume data never creates a directory",
                   !fm.fileExists(atPath: resumeDir(for: Profile.incognito.id, in: root).path))
            incognito.deleteResume(item)
            assert("forgetting private resume data removes it from memory",
                   incognito.readResume(item) == nil && item.resumeFile == nil)
        }
        assert("a fresh incognito download manager restores no records",
               Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true).items.isEmpty)
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
        try? (try! PropertyListSerialization.data(fromPropertyList: ["fixture": "resume"], format: .binary, options: 0)).write(to: blob)

        // A row still marked "running" on disk: the process died mid-transfer, so the
        // index is written by hand rather than through `add`, which is what a crash does.
        func plant(_ records: [Record], in dir: URL) {
            try? JSONEncoder().encode(records).write(to: listURL(for: defaultProfile, in: dir))
        }
        // A saved folder bookmark must reopen old rows even after the profile chooses a
        // different download folder. The stale destination paths stand in for a moved
        // folder; the bookmark resolves to its actual location.
        let scopedRoot = root.appendingPathComponent("scoped-history", isDirectory: true)
        let previous = scopedRoot.appendingPathComponent("previous", isDirectory: true)
        let current = scopedRoot.appendingPathComponent("current", isDirectory: true)
        try? fm.createDirectory(at: previous, withIntermediateDirectories: true)
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        let oldFinished = previous.appendingPathComponent("finished.zip")
        let oldPartial = previous.appendingPathComponent("partial.iso")
        try? Data("done".utf8).write(to: oldFinished)
        try? Data("half".utf8).write(to: oldPartial)
        var pausedHistory = Record(name: "partial.iso",
                                   destination: current.appendingPathComponent("partial.iso"),
                                   state: "paused")
        pausedHistory.resumeFile = "\(pausedHistory.id.uuidString).resume"
        let savedHistory = [Record(name: "finished.zip",
                                   destination: current.appendingPathComponent("finished.zip"),
                                   state: "done"), pausedHistory]
        let oldBookmark = (try? previous.bookmarkData(options: .withSecurityScope))
            ?? (try? previous.bookmarkData())
        if let oldBookmark,
           let encoded = try? JSONEncoder().encode(savedHistory),
           var rows = try? JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] {
            for i in rows.indices { rows[i]["destinationBookmark"] = oldBookmark.base64EncodedString() }
            if let data = try? JSONSerialization.data(withJSONObject: rows) {
                try? data.write(to: listURL(for: defaultProfile, in: scopedRoot))
            }
        }
        let scopedResume = resumeDir(for: defaultProfile, in: scopedRoot)
        try? fm.createDirectory(at: scopedResume, withIntermediateDirectories: true)
        try? (try! PropertyListSerialization.data(fromPropertyList: ["fixture": "resume"], format: .binary, options: 0))
            .write(to: scopedResume.appendingPathComponent(pausedHistory.resumeFile!))
        let oldHistory = Downloads(profileID: defaultProfile, directory: scopedRoot, sandboxed: true)
        let finishedHistory = oldHistory.items.first { $0.name == "finished.zip" }
        let resumableHistory = oldHistory.items.first { $0.name == "partial.iso" }
        assert("a prior folder bookmark keeps a finished download available",
               finishedHistory?.status == .done
                   && finishedHistory?.url?.resolvingSymlinksInPath().path
                       == oldFinished.resolvingSymlinksInPath().path)
        assert("a prior folder bookmark relocates the partial file",
               resumableHistory?.url?.resolvingSymlinksInPath().path
                   == oldPartial.resolvingSymlinksInPath().path)
        assert("a prior folder bookmark keeps a partial download resumable",
               resumableHistory.map { oldHistory.canResume($0) } == true)
        var savePanelRecord = Record(name: "finished.zip", destination: oldFinished, state: "done")
        savePanelRecord.destinationBookmarkIsFile = true
        let savePanelItem = oldHistory.add(savePanelRecord)
        oldHistory.captureFileGrant(savePanelItem)
        oldHistory.save()
        let fileGrantRecord = (try? Data(contentsOf: listURL(for: defaultProfile, in: scopedRoot)))
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) }?
            .first { $0.id == savePanelItem.id }
        assert("a new Save panel file gains a bookmark once WebKit creates it",
               fileGrantRecord?.destinationBookmark != nil
                   && fileGrantRecord?.destinationBookmarkIsFile == true)
        assert("a saved file grant restores the file itself after reload",
               Downloads(profileID: defaultProfile, directory: scopedRoot, sandboxed: true)
                   .items.first { $0.id == savePanelItem.id }?.status == .done)
        let migrationSuite = "vane.download-history-migration.\(UUID().uuidString)"
        if let choices = UserDefaults(suiteName: migrationSuite) {
            defer { UserDefaults.dropScratchSuite(migrationSuite) }
            let migrationRoot = root.appendingPathComponent("migration", isDirectory: true)
            try? fm.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
            plant([Record(name: "finished.zip", destination: oldFinished, state: "done")],
                  in: migrationRoot)
            DownloadLocation.setDirectory(previous, for: defaultProfile, defaults: choices)
            _ = Downloads(profileID: defaultProfile, directory: migrationRoot, sandboxed: true,
                          locationDefaults: choices)
            let updated = (try? Data(contentsOf: listURL(for: defaultProfile, in: migrationRoot)))
                .flatMap { try? JSONDecoder().decode([Record].self, from: $0) }
            assert("older rows in the selected folder gain a bookmark before the choice changes",
                   updated?.first?.destinationBookmark != nil)

            // A manager can have loaded while its old choice was unavailable. Selecting
            // that folder again must repair its already-loaded rows as well as the index.
            let laterID = UUID()
            let laterRoot = root.appendingPathComponent("late-migration", isDirectory: true)
            let laterFolder = root.appendingPathComponent("late-selected", isDirectory: true)
            try? fm.createDirectory(at: laterRoot, withIntermediateDirectories: true)
            let later = laterFolder.appendingPathComponent("late.zip")
            try? fm.createDirectory(at: laterFolder, withIntermediateDirectories: true)
            try? Data("late".utf8).write(to: later)
            try? JSONEncoder().encode([Record(name: "late.zip", destination: later, state: "done")])
                .write(to: listURL(for: laterID, in: laterRoot))
            try? fm.removeItem(at: laterFolder)
            let loaded = Downloads(profileID: laterID, directory: laterRoot, sandboxed: true,
                                   locationDefaults: choices)
            Downloads.cache[laterID] = loaded
            defer { Downloads.cache[laterID] = nil }
            let beforeChoice = loaded.items.first?.destinationBookmark == nil
            try? fm.createDirectory(at: laterFolder, withIntermediateDirectories: true)
            try? Data("late".utf8).write(to: later)
            let selectedAgain = DownloadLocation.setDirectory(laterFolder, for: laterID, defaults: choices)
            let repaired = (try? Data(contentsOf: listURL(for: laterID, in: laterRoot)))
                .flatMap { try? JSONDecoder().decode([Record].self, from: $0) }
            assert("reselecting a folder stores its grant", selectedAgain)
            assert("reselecting a folder starts with an ungranted loaded row", beforeChoice)
            assert("reselecting a folder backfills the loaded row",
                   loaded.items.first?.destinationBookmark != nil)
            assert("reselecting a folder persists the repaired row",
                   repaired?.first?.destinationBookmark != nil)

            let uncachedID = UUID()
            let uncachedRoot = root.appendingPathComponent("uncached-migration", isDirectory: true)
            let oldFolder = root.appendingPathComponent("uncached-old", isDirectory: true)
            let newFolder = root.appendingPathComponent("uncached-new", isDirectory: true)
            try? fm.createDirectory(at: uncachedRoot, withIntermediateDirectories: true)
            try? fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
            try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
            let oldFile = oldFolder.appendingPathComponent("legacy.zip")
            try? Data("old".utf8).write(to: oldFile)
            _ = DownloadLocation.setDirectory(oldFolder, for: uncachedID, defaults: choices,
                                              historyDirectory: uncachedRoot)
            try? JSONEncoder().encode([Record(name: "legacy.zip", destination: oldFile,
                                               state: "done")])
                .write(to: listURL(for: uncachedID, in: uncachedRoot))
            assert("settings-first change starts without a cached download manager",
                   Downloads.cache[uncachedID] == nil)
            _ = DownloadLocation.setDirectory(newFolder, for: uncachedID, defaults: choices,
                                              historyDirectory: uncachedRoot)
            let uncachedRows = (try? Data(contentsOf: listURL(for: uncachedID, in: uncachedRoot)))
                .flatMap { try? JSONDecoder().decode([Record].self, from: $0) }
            assert("settings-first change preserves old legacy row grant before replacing it",
                   uncachedRows?.first?.destinationBookmark != nil)
            assert("settings-first migrated row reopens after the old choice is gone",
                   Downloads(profileID: uncachedID, directory: uncachedRoot, sandboxed: true,
                             locationDefaults: choices).items.first?.status == .done)

            let disconnectedID = UUID()
            let disconnectedRoot = root.appendingPathComponent("disconnected-migration", isDirectory: true)
            let disconnectedOld = root.appendingPathComponent("disconnected-old", isDirectory: true)
            let disconnectedNew = root.appendingPathComponent("disconnected-new", isDirectory: true)
            try? fm.createDirectory(at: disconnectedRoot, withIntermediateDirectories: true)
            try? fm.createDirectory(at: disconnectedOld, withIntermediateDirectories: true)
            try? fm.createDirectory(at: disconnectedNew, withIntermediateDirectories: true)
            let disconnectedFile = disconnectedOld.appendingPathComponent("return.zip")
            try? Data("return".utf8).write(to: disconnectedFile)
            _ = DownloadLocation.setDirectory(disconnectedOld, for: disconnectedID,
                                              defaults: choices, historyDirectory: disconnectedRoot)
            let oldGrant = (choices.array(forKey: DownloadLocation.directoryKey(disconnectedID))
                            as? [Data])?.first
            try? JSONEncoder().encode([Record(name: "return.zip", destination: disconnectedFile,
                                               state: "done")])
                .write(to: listURL(for: disconnectedID, in: disconnectedRoot))
            try? fm.removeItem(at: disconnectedOld)
            _ = DownloadLocation.setDirectory(disconnectedNew, for: disconnectedID,
                                              defaults: choices, historyDirectory: disconnectedRoot)
            let disconnectedRows = (try? Data(contentsOf: listURL(for: disconnectedID,
                                                                    in: disconnectedRoot)))
                .flatMap { try? JSONDecoder().decode([Record].self, from: $0) }
            let pendingOld = (choices.array(forKey: DownloadLocation.pendingDirectoryKey(disconnectedID))
                              as? [Data]) ?? []
            assert("changing folders while the old volume is absent retains its raw grant",
                   oldGrant != nil && (disconnectedRows?.first?.destinationBookmark == oldGrant
                                       || pendingOld.contains(oldGrant!)))
            assert("absent-folder grant attaches immediately when its path still resolves",
                   oldGrant.flatMap(ScopedPaths.bookmarkedURL) == nil
                       || disconnectedRows?.first?.destinationBookmark == oldGrant)
            try? fm.createDirectory(at: disconnectedOld, withIntermediateDirectories: true)
            try? Data("return".utf8).write(to: disconnectedFile)
            let reconnected = Downloads(profileID: disconnectedID, directory: disconnectedRoot,
                                        sandboxed: true, locationDefaults: choices)
            let stillPending = (choices.array(forKey: DownloadLocation.pendingDirectoryKey(disconnectedID))
                                as? [Data]) ?? []
            assert("old grant remains recoverable if a recreated folder has a new identity",
                   reconnected.items.first?.destinationBookmark == oldGrant
                       || (oldGrant != nil && stillPending.contains(oldGrant!)))

            // A restored volume retains its file identity. Seed a resolvable pending
            // bookmark directly so the later-load migration can be checked without a mount.
            let pendingID = UUID()
            let pendingRoot = root.appendingPathComponent("pending-migration", isDirectory: true)
            let pendingFolder = root.appendingPathComponent("pending-restored", isDirectory: true)
            try? fm.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
            try? fm.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
            let pendingFile = pendingFolder.appendingPathComponent("restored.zip")
            try? Data("ready".utf8).write(to: pendingFile)
            let pendingGrant = ScopedPaths.bookmarkForLater(pendingFolder)
            choices.set(pendingGrant.map { [$0] }, forKey: DownloadLocation.pendingDirectoryKey(pendingID))
            try? JSONEncoder().encode([Record(name: "restored.zip", destination: pendingFile,
                                               state: "done")])
                .write(to: listURL(for: pendingID, in: pendingRoot))
            let pendingRecovered = Downloads(profileID: pendingID, directory: pendingRoot,
                                             sandboxed: true, locationDefaults: choices)
            assert("a pending old grant attaches to its legacy row after resolution",
                   pendingGrant != nil && pendingRecovered.items.first?.destinationBookmark == pendingGrant
                       && pendingRecovered.items.first?.status == .done)
            assert("resolved pending grant is removed from preferences after migration",
                   choices.object(forKey: DownloadLocation.pendingDirectoryKey(pendingID)) == nil)
        } else {
            assert("a throwaway migration defaults suite is available", false)
        }
        try? fm.removeItem(at: previous)
        if let finishedHistory { oldHistory.reveal(finishedHistory) }
        assert("an unavailable historical folder marks its finished row missing",
               finishedHistory?.status == .missing)
        let pausedWhileDisconnected = resumableHistory.map { oldHistory.resume($0) } == false
        assert("an unavailable historical folder keeps its partial transfer paused",
               pausedWhileDisconnected && resumableHistory?.status == .paused)
        assert("an unavailable historical folder keeps its resume blob",
               fm.fileExists(atPath: scopedResume
                   .appendingPathComponent(pausedHistory.resumeFile!).path))
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

        let scopeRoot = root.appendingPathComponent("row-scopes", isDirectory: true)
        let scopedFiles = scopeRoot.appendingPathComponent("files", isDirectory: true)
        try? fm.createDirectory(at: scopedFiles, withIntermediateDirectories: true)
        let sharedGrant = ScopedPaths.bookmarkForLater(scopedFiles)
        if let sharedGrant {
            let firstFile = scopedFiles.appendingPathComponent("first.txt")
            let secondFile = scopedFiles.appendingPathComponent("second.txt")
            try? Data("one".utf8).write(to: firstFile)
            try? Data("two".utf8).write(to: secondFile)
            let first = Record(name: "first.txt", destination: firstFile, state: "done",
                               destinationBookmark: sharedGrant)
            let second = Record(name: "second.txt", destination: secondFile, state: "done",
                                destinationBookmark: sharedGrant)
            try? fm.createDirectory(at: scopeRoot, withIntermediateDirectories: true)
            try? JSONEncoder().encode([first, second])
                .write(to: listURL(for: defaultProfile, in: scopeRoot))
            let scoped = Downloads(profileID: defaultProfile, directory: scopeRoot, sandboxed: true)
            assert("two history rows share a started folder scope",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == 2)
            let scopeSuite = "vane.download-scope-owners.\(UUID().uuidString)"
            if let scopeChoices = UserDefaults(suiteName: scopeSuite) {
                defer { UserDefaults.dropScratchSuite(scopeSuite) }
                _ = ScopedPaths.replace(scopedFiles, at: "chosen", in: scopeChoices)
                assert("a preference and two rows share one folder scope",
                       ScopedPaths.activeOwnerCount(for: scopedFiles) == 3)
                _ = ScopedPaths.replace(nil, at: "chosen", in: scopeChoices)
                assert("replacing the preference keeps both row leases alive",
                       ScopedPaths.activeOwnerCount(for: scopedFiles) == 2)
            } else {
                assert("a scope-owner defaults suite is available", false)
            }
            if let firstItem = scoped.items.first(where: { $0.id == first.id }) { scoped.forget(firstItem) }
            assert("forgetting one row leaves its sibling's scope active",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == 1)
            scoped.clear()
            assert("clearing history releases the final row scope",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == 0)

            let cappedRecords = (0...historyLimit).map { number in
                Record(name: "old-\(number).txt",
                       destination: scopedFiles.appendingPathComponent("old-\(number).txt"),
                       state: "done", destinationBookmark: sharedGrant)
            }
            try? JSONEncoder().encode(cappedRecords)
                .write(to: listURL(for: defaultProfile, in: scopeRoot))
            let cappedScopes = Downloads(profileID: defaultProfile, directory: scopeRoot,
                                         sandboxed: true)
            assert("loaded rows each hold a scope lease before history trimming",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == historyLimit + 1)
            cappedScopes.save()
            assert("history eviction releases only the removed row lease",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == historyLimit)
            cappedScopes.clear()
            let removedProfile = UUID()
            try? JSONEncoder().encode([first])
                .write(to: listURL(for: removedProfile, in: scopeRoot))
            let profileScopes = Downloads(profileID: removedProfile, directory: scopeRoot,
                                          sandboxed: true)
            Downloads.cache[removedProfile] = profileScopes
            assert("a cached profile download holds its row scope",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == 1)
            Downloads.forget(removedProfile, in: scopeRoot)
            assert("deleting a profile releases its row scope",
                   ScopedPaths.activeOwnerCount(for: scopedFiles) == 0)
        } else {
            assert("a shared row grant can be made for lifecycle checks", false)
        }

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
            defer { UserDefaults.dropScratchSuite(suite) }
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
            assert("a chosen folder is persisted as a bookmark, not a path",
                   (scratch.array(forKey: DownloadLocation.directoryKey(id)) as? [Data])?.count == 1)
            assert("a download row copies the chosen folder's grant",
                   DownloadLocation.bookmark(for: picked.appendingPathComponent("report.pdf"),
                                             profileID: id, defaults: scratch)
                       == (scratch.array(forKey: DownloadLocation.directoryKey(id)) as? [Data])?.first)
            let panelFolder = root.appendingPathComponent("panel-selected-folder", isDirectory: true)
            try? fm.createDirectory(at: panelFolder, withIntermediateDirectories: true)
            let selectedFile = panelFolder.appendingPathComponent("picked-by-save-panel.pdf")
            assert("a not-yet-created Save panel file does not borrow its parent grant",
                   DownloadLocation.bookmark(for: selectedFile, profileID: id,
                                             defaults: scratch, selectedFile: true) == nil)
            try? Data("saved".utf8).write(to: selectedFile)
            let selectedGrant = DownloadLocation.bookmark(for: selectedFile, profileID: id,
                                                          defaults: scratch, selectedFile: true)
            let checkOwner = UUID()
            assert("a Save panel file gets its own grant, not a parent folder grant",
                   selectedGrant.flatMap { ScopedPaths.accessBookmark($0, owner: checkOwner) }?
                       .resolvingSymlinksInPath().path == selectedFile.resolvingSymlinksInPath().path)
            ScopedPaths.releaseBookmark(owner: checkOwner)
            assert("a chosen folder is where downloads go",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       .resolvingSymlinksInPath().path == picked.resolvingSymlinksInPath().path)
            assert("the choice is per profile, not global",
                   DownloadLocation.directory(for: other, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            try? fm.removeItem(at: picked)
            assert("a folder that has since been deleted falls back rather than failing",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            let disconnected = root.appendingPathComponent("disconnected", isDirectory: true)
            try? fm.createDirectory(at: disconnected, withIntermediateDirectories: true)
            let bookmark = (try? disconnected.bookmarkData(options: .withSecurityScope))
                ?? (try? disconnected.bookmarkData())
            try? fm.removeItem(at: disconnected)
            scratch.set(bookmark.map { [$0] }, forKey: DownloadLocation.directoryKey(id))
            assert("an unavailable folder falls back until its volume returns",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            assert("an unavailable folder keeps its bookmark for a later relaunch",
                   (scratch.array(forKey: DownloadLocation.directoryKey(id)) as? [Data])?.count == 1)
            let notADirectory = root.appendingPathComponent("afile.txt")
            try? Data("x".utf8).write(to: notADirectory)
            let beforeInvalid = scratch.array(forKey: DownloadLocation.directoryKey(id)) as? [Data]
            assert("a file cannot replace the saved folder",
                   !DownloadLocation.setDirectory(notADirectory, for: id, defaults: scratch)
                       && (scratch.array(forKey: DownloadLocation.directoryKey(id)) as? [Data])
                           == beforeInvalid)
            assert("a file where a folder should be falls back too",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads)
            DownloadLocation.setDirectory(nil, for: id, defaults: scratch)
            assert("clearing the choice goes back to the system folder",
                   scratch.object(forKey: DownloadLocation.directoryKey(id)) == nil)
            scratch.set("", forKey: DownloadLocation.directoryKey(id))
            assert("an empty legacy path stays unset instead of choosing the working directory",
                   DownloadLocation.directory(for: id, defaults: scratch)
                       == DownloadLocation.systemDownloads
                       && scratch.object(forKey: DownloadLocation.directoryKey(id)) == nil)
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
/// The user's choice is a security-scoped bookmark. A path alone loses the open panel's
/// sandbox grant at relaunch; resolving the bookmark reopens that grant before WebKit
/// decides where to write the next download.
@MainActor enum DownloadLocation {
    /// The system folder, and what an unset preference means.
    nonisolated static var systemDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    nonisolated static func directoryKey(_ id: UUID) -> String {
        ProfileManager.defaultsKey("downloadDirectory", id)
    }
    nonisolated static func pendingDirectoryKey(_ id: UUID) -> String {
        ProfileManager.defaultsKey("downloadDirectoryPendingHistory", id)
    }
    nonisolated static func askKey(_ id: UUID) -> String {
        ProfileManager.defaultsKey("downloadAskEveryTime", id)
    }

    /// Where this profile files its downloads. A stored folder that has since been deleted
    /// or renamed is not an error the user should meet as a failed download.
    static func directory(for id: UUID, defaults: UserDefaults = .vane,
                          fm: FileManager = .default) -> URL {
        let key = directoryKey(id)
        // Older builds saved a path. Upgrade it if it is still accessible (for example,
        // a folder under ~/Downloads); otherwise make the default visible so the user can
        // pick it again. A path outside the sandbox cannot grant itself access.
        if let legacy = defaults.string(forKey: key) {
            guard !legacy.isEmpty else {
                defaults.removeObject(forKey: key)
                return systemDownloads
            }
            let url = URL(fileURLWithPath: legacy, isDirectory: true)
            if !setDirectory(url, for: id, defaults: defaults) {
                defaults.removeObject(forKey: key)
                return systemDownloads
            }
        }
        guard let url = ScopedPaths.availableURL(key, in: defaults) else { return systemDownloads }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: url.path) else {
            return systemDownloads
        }
        return url
    }

    /// Nil resets to the system folder. A failed choice leaves the previous one intact.
    @discardableResult
    static func setDirectory(_ url: URL?, for id: UUID, defaults: UserDefaults = .vane,
                             historyDirectory: URL = Store.directory) -> Bool {
        let key = directoryKey(id)
        if let url {
            var isDirectory: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, FileManager.default.isWritableFile(atPath: url.path) else {
                return false
            }
        }
        // Keep legacy rows in the old folder reachable even when Settings changes before
        // the downloads manager has ever been constructed this launch.
        let oldGrant = (defaults.array(forKey: key) as? [Data])?.first
        let oldFolder = oldGrant.flatMap(ScopedPaths.bookmarkedURL)
        let changedFolder = oldGrant != nil && (oldFolder == nil ||
            oldFolder?.resolvingSymlinksInPath().path != url?.resolvingSymlinksInPath().path)
        if changedFolder, let oldGrant, let oldFolder {
            if Downloads.cache[id] != nil {
                Downloads.backfillCachedRows(for: id, folder: oldFolder, grant: oldGrant)
            } else {
                Downloads.backfillPersistedRows(for: id, in: historyDirectory,
                                                folder: oldFolder, grant: oldGrant)
            }
        }
        guard ScopedPaths.replace(url, at: key, in: defaults) else { return false }
        if changedFolder, oldFolder == nil, let oldGrant {
            let pendingKey = pendingDirectoryKey(id)
            var pending = (defaults.array(forKey: pendingKey) as? [Data]) ?? []
            if !pending.contains(oldGrant) { pending.append(oldGrant) }
            defaults.set(pending, forKey: pendingKey)
        }
        guard let url else { return true }
        if let grant = (defaults.array(forKey: key) as? [Data])?.first {
            Downloads.backfillCachedRows(for: id, folder: url, grant: grant)
        }
        return true
    }

    /// Copy the current folder's grant into a download row when it matches. A Save panel
    /// grants only its selected file, which may not exist until WebKit starts writing.
    /// An unrelated parent folder cannot mint its own sandbox grant from a bare path.
    static func bookmark(for destination: URL, profileID: UUID,
                         defaults: UserDefaults = .vane, selectedFile: Bool = false) -> Data? {
        if selectedFile {
            guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
            return ScopedPaths.bookmarkForLater(destination)
        }
        let folder = destination.deletingLastPathComponent()
        let key = directoryKey(profileID)
        if let data = (defaults.array(forKey: key) as? [Data])?.first,
           let selected = ScopedPaths.availableURL(key, in: defaults),
           selected.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path {
            return data
        }
        return nil
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
        guard setDirectory(url, for: id) else {
            let alert = NSAlert()
            alert.messageText = "Could not use this download folder"
            alert.informativeText = "Choose a writable folder that Vane can reopen after relaunch."
            alert.runModal()
            return nil
        }
        return url
    }

    /// The folder's name, as the settings row draws it: the last component, or "Downloads"
    /// for the system folder wherever it is and whatever the user has renamed it to.
    nonisolated static func label(_ url: URL) -> String {
        url.path == systemDownloads.path ? "Downloads" : url.lastPathComponent
    }
}
