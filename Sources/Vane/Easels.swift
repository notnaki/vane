import Foundation
import Combine
import ImageIO

struct EaselPoint: Codable, Equatable { var x: Double; var y: Double }

struct EaselItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case note, link, image, drawing, text, ellipse, rectangle, diamond, arrow, line }
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

struct EaselBoard: Identifiable, Codable, Equatable {
    var version = 1
    var id = UUID()
    var title = "Untitled Easel"
    var modified = Date.now
    var items: [EaselItem] = []
}

/// One repository per profile. Writes are atomic and published only after they succeed.
/// Images are embedded in the document so export/import never relies on an outside path.
@MainActor final class EaselStore: ObservableObject {
    private static var stores: [URL: EaselStore] = [:]
    static func shared(profileID: UUID, directory: URL) -> EaselStore {
        let key = file(profileID: profileID, directory: directory).standardizedFileURL
        if let store = stores[key] { return store }
        let store = EaselStore(profileID: profileID, directory: directory)
        stores[key] = store
        return store
    }
    static func forget(_ profileID: UUID, directory: URL) {
        let key = file(profileID: profileID, directory: directory).standardizedFileURL
        if let store = stores.removeValue(forKey: key) {
            store.invalidated = true
            store.boards = []
            store.past.removeAll(); store.future.removeAll()
        }
        try? FileManager.default.removeItem(at: key)
    }

    enum Failure: LocalizedError {
        case damaged, invalid, tooLarge, missing
        var errorDescription: String? {
            switch self {
            case .damaged: "The saved Easels could not be read. The original file has been kept. Restore it from a backup, then choose Retry."
            case .invalid: "This Easel contains unsupported or invalid content."
            case .tooLarge: "This Easel is too large. Use fewer or smaller images."
            case .missing: "This Easel no longer exists."
            }
        }
    }
    struct Archive: Codable { var version = 1; var boards: [EaselBoard] }
    static let canvasWidth = 6000.0
    static let canvasHeight = 4000.0
    static let imageLimit = 8 * 1024 * 1024
    static let fileLimit = 64 * 1024 * 1024
    let profileID: UUID
    let directory: URL
    @Published private(set) var boards: [EaselBoard] = []
    @Published private(set) var error: String?
    private var readable = true
    private var invalidated = false
    private var past: [UUID: [EaselBoard]] = [:]
    private var future: [UUID: [EaselBoard]] = [:]

    init(profileID: UUID, directory: URL) {
        self.profileID = profileID
        self.directory = directory
        reload()
    }
    static func file(profileID: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("easels-\(profileID.uuidString).json")
    }
    func reload() {
        guard !invalidated else { return }
        let url = Self.file(profileID: profileID, directory: directory)
        do {
            let archive: Archive
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= Self.fileLimit else { throw Failure.tooLarge }
                archive = try JSONDecoder().decode(Archive.self, from: data)
            } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
                archive = Archive(boards: [])
            }
            guard archive.version == 1, archive.boards.count <= 200,
                  Set(archive.boards.map(\.id)).count == archive.boards.count else { throw Failure.invalid }
            try archive.boards.forEach(Self.validate)
            boards = archive.boards.sorted { $0.modified > $1.modified }
            readable = true
            error = nil
            past.removeAll(); future.removeAll()
        } catch {
            readable = false
            self.error = Failure.damaged.localizedDescription
        }
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
        guard !invalidated else { throw Failure.missing }
        guard readable else { throw Failure.damaged }
        guard candidate.count <= 200 else { throw Failure.tooLarge }
        try candidate.forEach(Self.validate)
        let data = try JSONEncoder().encode(Archive(boards: candidate))
        guard data.count <= Self.fileLimit else { throw Failure.tooLarge }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: Self.file(profileID: profileID, directory: directory), options: .atomic)
        } catch {
            self.error = "Easels could not be saved: \(error.localizedDescription)"
            throw error
        }
        boards = candidate.sorted { $0.modified > $1.modified }
        error = nil
    }
    static func validate(_ board: EaselBoard) throws {
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
