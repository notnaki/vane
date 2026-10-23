import Foundation
import Combine
import ImageIO

struct EaselPoint: Codable, Equatable, Sendable { var x: Double; var y: Double }

struct EaselItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case note, link, image, drawing, text, ellipse, rectangle, diamond, arrow, line }
    var id = UUID()
    var kind: Kind
    var text = ""
    var source = ""
    var image: Data?
    var points: [EaselPoint] = []
    var color = "yellow"
    var strokeWidth: Double?
    var fillColor: String?
    var fontSize: Double?
    var style: EaselObjectStyle?
    var x: Double = 160
    var y: Double = 160
    var width: Double = 280
    var height: Double = 200

    var textSize: Double { fontSize ?? (kind == .note ? 18 : kind == .text ? 28 : 20) }

    static func validColor(_ value: String) -> Bool {
        ["yellow", "pink", "blue", "green", "ink", "orange", "red", "cyan", "purple", "white", "gray"].contains(value)
            || (value.count == 7 && value.first == "#" && UInt32(value.dropFirst(), radix: 16) != nil)
    }
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

struct EaselBoard: Identifiable, Codable, Equatable, Sendable {
    var version = 1
    var id = UUID()
    var title = "Untitled Easel"
    var modified = Date.now
    var items: [EaselItem] = []
}

/// A repository-owned executor caches encoded boards. An edit validates/encodes only
/// its changed board; combining already encoded fragments and the atomic write stay here.
private actor EaselArchiveWriter {
    private var encoded: [UUID: Data] = [:]
    private var revisions: [UUID: EaselBoard] = [:]
    func load(_ url: URL, inspection: @Sendable (String) throws -> Void) throws -> [EaselBoard] {
        try inspection("load")
        let boards = try EaselStore.read(url)
        var prepared: [UUID: Data] = [:]
        for board in boards { prepared[board.id] = try JSONEncoder().encode(board) }
        encoded = prepared
        revisions = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        return boards
    }
    func save(_ boards: [EaselBoard], changed: [EaselBoard], directory: URL, url: URL,
              inspection: @Sendable (String) throws -> Void) throws {
        try inspection("save")
        guard boards.count <= 200 else { throw EaselStore.Failure.tooLarge }
        var prepared = encoded
        var versions = revisions
        for board in changed {
            try inspection("validate:" + board.id.uuidString)
            try EaselStore.validate(board)
            try inspection("encode:" + board.id.uuidString)
            prepared[board.id] = try JSONEncoder().encode(board); versions[board.id] = board
        }
        var data = Data("{\"version\":1,\"boards\":[".utf8)
        for (index, board) in boards.enumerated() {
            // Imported boards and undo snapshots are already validated, but may not
            // have an encoded entry matching this revision.
            let bytes: Data
            if versions[board.id] == board, let cached = prepared[board.id] { bytes = cached }
            else {
                try inspection("encode:" + board.id.uuidString)
                bytes = try JSONEncoder().encode(board); prepared[board.id] = bytes; versions[board.id] = board
            }
            guard bytes.count <= EaselStore.fileLimit - data.count - 2 else { throw EaselStore.Failure.tooLarge }
            if index > 0 { data.append(0x2c) }
            data.append(bytes)
        }
        data.append(contentsOf: [0x5d, 0x7d])
        guard data.count <= EaselStore.fileLimit else { throw EaselStore.Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let retained = Set(boards.map(\.id))
        encoded = prepared.filter { retained.contains($0.key) }
        revisions = versions.filter { retained.contains($0.key) }
    }
}

/// One repository per profile. Writes are atomic and published only after they succeed.
/// Images are embedded in the document so export/import never relies on an outside path.
@MainActor final class EaselStore: ObservableObject {
    private static var retiredTasks: [URL: Task<Void, Never>] = [:]
    private static var stores: [URL: EaselStore] = [:]
    static func shared(profileID: UUID, directory: URL,
                       inspection: @escaping @Sendable (String) throws -> Void = { _ in }) -> EaselStore {
        let key = file(profileID: profileID, directory: directory).standardizedFileURL
        if let store = stores[key] { return store }
        let store = EaselStore(profileID: profileID, directory: directory, background: true,
                               inspection: inspection, predecessor: retiredTasks[key])
        stores[key] = store
        return store
    }
    static func forget(_ profileID: UUID, directory: URL) {
        let key = file(profileID: profileID, directory: directory).standardizedFileURL
        let store = stores.removeValue(forKey: key)
        store?.invalidated = true
        store?.boards = []
        store?.past.removeAll(); store?.future.removeAll()
        // A subsequent repository for this URL waits for this retirement too; deleting
        // an older generation must never remove a replacement store's archive.
        let pending = store?.tail, previous = retiredTasks[key]
        retiredTasks[key] = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            if let pending { await pending.value }
            try? FileManager.default.removeItem(at: key)
        }
    }
    static func waitForRetirement(profileID: UUID, directory: URL) async {
        let key = file(profileID: profileID, directory: directory).standardizedFileURL
        if let pending = retiredTasks[key] { await pending.value }
    }

    enum Failure: LocalizedError {
        case damaged, invalid, tooLarge, missing, loading, exiting
        var errorDescription: String? {
            switch self {
            case .damaged: "The saved Easels could not be read. The original file has been kept. Restore it from a backup, then choose Retry."
            case .invalid: "This Easel contains unsupported or invalid content."
            case .tooLarge: "This Easel is too large. Use fewer or smaller images."
            case .missing: "This Easel no longer exists."
            case .loading: "Easels are still loading. Try again."
            case .exiting: "Vane is finishing a restore or quit. Try again when it finishes."
            }
        }
    }
    struct Archive: Codable, Sendable { var version = 1; var boards: [EaselBoard] }
    nonisolated static let canvasWidth = 6000.0
    nonisolated static let canvasHeight = 4000.0
    nonisolated static let imageLimit = 8 * 1024 * 1024
    nonisolated static let fileLimit = 64 * 1024 * 1024
    let profileID: UUID
    let directory: URL
    @Published private(set) var boards: [EaselBoard] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    let background: Bool
    private var tail: Task<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused = false
    private let writer = EaselArchiveWriter()
    private let inspection: @Sendable (String) throws -> Void
    private var hasMutationIntent = false
    private var readable = true
    private var invalidated = false
    private var past: [UUID: [EaselBoard]] = [:]
    private var future: [UUID: [EaselBoard]] = [:]

    init(profileID: UUID, directory: URL, background: Bool = false,
         inspection: @escaping @Sendable (String) throws -> Void = { _ in },
         predecessor: Task<Void, Never>? = nil) {
        self.profileID = profileID
        self.directory = directory
        self.background = background
        self.inspection = inspection
        self.tail = predecessor
        reload()
    }
    nonisolated static func file(profileID: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("easels-\(profileID.uuidString).json")
    }
    /// The synchronous constructor/mutations support offline checks and fixture callers.
    /// Every shared UI repository uses this ordered background path.
    func reload() {
        guard !invalidated else { return }
        hasMutationIntent = false
        if background {
            loading = true
            generation &+= 1
            let previous = tail
            let task = Task { @MainActor [self] in
                if let previous { await previous.value }
                await waitForResume()
                guard !invalidated else { loading = false; return }
                do {
                    let url = Self.file(profileID: profileID, directory: directory), inspection = inspection
                    let loaded = try await writer.load(url, inspection: inspection)
                    guard !invalidated else { loading = false; return }
                    publishLoad(loaded)
                } catch { readable = false; self.error = Failure.damaged.localizedDescription }
                loading = false
            }
            tail = task
        } else {
            do { publishLoad(try Self.read(Self.file(profileID: profileID, directory: directory))) }
            catch { readable = false; self.error = Failure.damaged.localizedDescription }
        }
    }
    private func publishLoad(_ loaded: [EaselBoard]) {
        boards = loaded; readable = true; error = nil
        past.removeAll(); future.removeAll()
    }
    fileprivate nonisolated static func read(_ url: URL) throws -> [EaselBoard] {
        let archive: Archive
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= fileLimit else { throw Failure.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= fileLimit else { throw Failure.tooLarge }
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            archive = Archive(boards: [])
        }
        guard archive.version == 1, archive.boards.count <= 200,
              Set(archive.boards.map(\.id)).count == archive.boards.count else { throw Failure.invalid }
        try archive.boards.forEach(validate)
        return archive.boards.sorted { $0.modified > $1.modified }
    }
    func waitUntilReady() async { if let tail { await tail.value } }
    func flush(allowUnreadableOriginal: Bool = false) async throws {
        // Include work admitted while waiting, rather than returning an older generation.
        while true {
            let asked = generation
            for task in intents.values { await task.value }
            if let pending = tail { await pending.value }
            if generation == asked { break }
        }
        if let error {
            if allowUnreadableOriginal && !readable && !hasMutationIntent { return }
            throw NSError(domain: "Vane.Easels", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
    static func flushAll(directory: URL) async throws {
        for store in stores.values.filter({ $0.directory.standardizedFileURL == directory.standardizedFileURL }) {
            try await store.flush()
        }
    }
    static func drainAllPendingWrites(directory: URL) async throws {
        for store in stores.values.filter({ $0.directory.standardizedFileURL == directory.standardizedFileURL }) {
            try await store.flush(allowUnreadableOriginal: true)
        }
    }
    private func waitForResume() async {
        while paused { await withCheckedContinuation { pauseWaiters.append($0) } }
    }
    /// Barrier used by backup after its other UI-state capture. New edits queue behind it.
    static func pauseAll(directory: URL) async throws -> [EaselStore] {
        let selected = stores.values.filter { $0.directory.standardizedFileURL == directory.standardizedFileURL }
        var paused: [EaselStore] = []
        do {
            for store in selected { try await store.flush(); store.paused = true; paused.append(store) }
            return paused
        } catch { resumeAll(paused); throw error }
    }
    static func resumeAll(_ stores: [EaselStore]) {
        for store in stores {
            store.paused = false
            let waiting = store.pauseWaiters; store.pauseWaiters = []
            waiting.forEach { $0.resume() }
        }
    }
    private var intents: [UUID: Task<Void, Never>] = [:]
    func trackIntent(_ task: Task<Void, Never>, id: UUID) { intents[id] = task; generation &+= 1 }
    func finishIntent(_ id: UUID) { intents[id] = nil }
    private var generation = 0
    @TaskLocal nonisolated static var admittedIntent = false
    private func ordered<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        guard Self.admittedIntent || !AppLifecycle.shared.persistenceExitInProgress else { throw Failure.exiting }
        hasMutationIntent = true
        let previous = tail
        generation &+= 1
        // An admitted mutation belongs to the repository. Cancelling a view task must not
        // interrupt an atomic write or leave disk newer than the published/undo state.
        let task = Task { @MainActor [self] in
            if let previous { await previous.value }
            await waitForResume()
            guard !invalidated else { throw Failure.missing }
            return try await work()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
    @discardableResult func createAsync(title: String = "Untitled Easel") async throws -> EaselBoard {
        try await ordered { [self] in
            let board = EaselBoard(title: title)
            try await commitAsync(boards + [board], changed: [board])
            return board
        }
    }
    func saveAsync(_ board: EaselBoard) async throws {
        try await ordered { [self] in
            guard let previous = self.board(board.id) else { throw Failure.missing }
            guard previous != board else { return }
            var updated = board; updated.modified = .now
            try await commitAsync(boards.map { $0.id == board.id ? updated : $0 }, changed: [updated])
            past[board.id, default: []].append(previous)
            if past[board.id]!.count > 50 { past[board.id]!.removeFirst() }
            future[board.id] = []
        }
    }
    func deleteAsync(_ id: UUID) async throws {
        try await ordered { [self] in
            try await commitAsync(boards.filter { $0.id != id }, changed: [])
            past[id] = nil; future[id] = nil
        }
    }
    func undoAsync(_ id: UUID) async throws {
        try await ordered { [self] in
            guard let previous = past[id]?.last, let current = board(id) else { return }
            try await commitAsync(boards.map { $0.id == id ? previous : $0 }, changed: [previous])
            past[id]?.removeLast(); future[id, default: []].append(current)
        }
    }
    func redoAsync(_ id: UUID) async throws {
        try await ordered { [self] in
            guard let next = future[id]?.last, let current = board(id) else { return }
            try await commitAsync(boards.map { $0.id == id ? next : $0 }, changed: [next])
            future[id]?.removeLast(); past[id, default: []].append(current)
        }
    }
    @discardableResult func importBoardAsync(_ data: Data) async throws -> EaselBoard {
        try await ordered { [self] in
            let board = try await Task.detached(priority: .userInitiated) {
                guard data.count <= Self.fileLimit else { throw Failure.tooLarge }
                var board = try JSONDecoder().decode(EaselBoard.self, from: data)
                try Self.validate(board)
                board.id = UUID(); board.modified = .now
                board.items = board.items.map { item in var copy = item; copy.id = UUID(); return copy }
                return board
            }.value
            try await commitAsync(boards + [board], changed: [])
            return board
        }
    }
    private func commitAsync(_ candidate: [EaselBoard], changed: [EaselBoard]) async throws {
        guard !invalidated else { throw Failure.missing }
        guard readable else { throw Failure.damaged }
        let directory = directory, url = Self.file(profileID: profileID, directory: directory), inspection = inspection
        do {
            try await writer.save(candidate, changed: changed, directory: directory, url: url, inspection: inspection)
        } catch {
            self.error = "Easels could not be saved: \(error.localizedDescription)"
            throw error
        }
        guard !invalidated else { throw Failure.missing }
        boards = candidate.sorted { $0.modified > $1.modified }; error = nil
    }
    func board(_ id: UUID) -> EaselBoard? { boards.first { $0.id == id } }
    func canUndo(_ id: UUID) -> Bool { !(past[id] ?? []).isEmpty }
    func canRedo(_ id: UUID) -> Bool { !(future[id] ?? []).isEmpty }

    @discardableResult func create(title: String = "Untitled Easel") throws -> EaselBoard {
        let board = EaselBoard(title: title)
        try commit(boards + [board])
        return board
    }
    func save(_ board: EaselBoard) throws {
        guard let previous = self.board(board.id) else { throw Failure.missing }
        guard previous != board else { return }
        var updated = board
        updated.modified = .now
        try commit(boards.map { $0.id == board.id ? updated : $0 })
        past[board.id, default: []].append(previous)
        if past[board.id]!.count > 50 { past[board.id]!.removeFirst() }
        future[board.id] = []
    }
    func delete(_ id: UUID) throws {
        try commit(boards.filter { $0.id != id })
        past[id] = nil; future[id] = nil
    }
    func undo(_ id: UUID) throws {
        guard let previous = past[id]?.last, let current = board(id) else { return }
        try commit(boards.map { $0.id == id ? previous : $0 })
        past[id]?.removeLast()
        future[id, default: []].append(current)
    }
    func redo(_ id: UUID) throws {
        guard let next = future[id]?.last, let current = board(id) else { return }
        try commit(boards.map { $0.id == id ? next : $0 })
        future[id]?.removeLast()
        past[id, default: []].append(current)
    }
    @discardableResult func importBoard(_ data: Data) throws -> EaselBoard {
        guard data.count <= Self.fileLimit else { throw Failure.tooLarge }
        var board = try JSONDecoder().decode(EaselBoard.self, from: data)
        try Self.validate(board)
        board.id = UUID()
        board.modified = .now
        board.items = board.items.map { item in var copy = item; copy.id = UUID(); return copy }
        try commit(boards + [board])
        return board
    }
    private func commit(_ candidate: [EaselBoard]) throws {
        guard !loading else { throw Failure.loading }
        guard !invalidated else { throw Failure.missing }
        guard readable else { throw Failure.damaged }
        do { try Self.persist(candidate, changed: candidate, directory: directory,
                              url: Self.file(profileID: profileID, directory: directory)) }
        catch { self.error = "Easels could not be saved: \(error.localizedDescription)"; throw error }
        boards = candidate.sorted { $0.modified > $1.modified }
        error = nil
    }
    private nonisolated static func persist(_ candidate: [EaselBoard], changed: [EaselBoard], directory: URL, url: URL) throws {
        guard candidate.count <= 200 else { throw Failure.tooLarge }
        try changed.forEach(validate)
        let data = try JSONEncoder().encode(Archive(boards: candidate))
        guard data.count <= fileLimit else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    nonisolated static func validate(_ board: EaselBoard) throws {
        guard board.version == 1, board.title.count <= 200, board.modified.timeIntervalSince1970.isFinite,
              board.items.count <= 256, Set(board.items.map(\.id)).count == board.items.count else { throw Failure.invalid }
        for item in board.items {
            try item.style?.validate()
            guard [item.x, item.y, item.width, item.height].allSatisfy(\.isFinite),
                  item.x >= 0, item.y >= 0, item.width >= 80, item.height >= 60,
                  item.width <= 4096, item.height <= 4096,
                  item.x + item.width <= canvasWidth, item.y + item.height <= canvasHeight,
                  item.text.count <= 100_000, item.source.count <= 8192,
                  item.points.count <= 5000,
                  item.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x <= item.width && $0.y <= item.height }),
                  EaselItem.validColor(item.color),
                  item.strokeWidth.map({ $0.isFinite && (1...8).contains($0) }) ?? true,
                  item.fillColor.map(EaselItem.validColor) ?? true,
                  item.fontSize.map({ $0.isFinite && (12...96).contains($0) }) ?? true
            else { throw Failure.invalid }
            if item.kind == .link && EaselItem.webURL(item.source) == nil { throw Failure.invalid }
            if !item.source.isEmpty && EaselItem.webURL(item.source) == nil { throw Failure.invalid }
            if item.kind == .image {
                guard let image = item.image, !image.isEmpty, image.count <= imageLimit else { throw Failure.tooLarge }
                guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 16_000, height <= 16_000,
                      width * height <= 32_000_000 else { throw Failure.invalid }
            }
        }
    }
}
