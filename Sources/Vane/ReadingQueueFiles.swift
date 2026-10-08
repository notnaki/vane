import Foundation
import Darwin

/// Exact queue ownership grammar shared with backup/restore. Staging is deliberately absent.
enum ReadingQueueFiles {
    static func root(in directory: URL) -> URL { directory.appendingPathComponent("ReadingQueue", isDirectory: true) }
    static func profileURL(_ id: UUID, in directory: URL) -> URL { root(in: directory).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    static func articleURL(profileID: UUID, articleID: UUID, in directory: URL) -> URL {
        profileURL(profileID, in: directory).appendingPathComponent(articleID.uuidString.lowercased(), isDirectory: true)
    }
    static func canonicalUUID(_ value: String) -> UUID? { UUID(uuidString: value).flatMap { $0.uuidString.lowercased() == value ? $0 : nil } }
    static func parseOwnedName(_ name: String) -> (profileID: UUID, articleID: UUID)? {
        let p = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4 || p.count == 5, p[0] == "ReadingQueue",
              let profile = canonicalUUID(p[1]), profile != Profile.incognito.id,
              let article = canonicalUUID(p[2]) else { return nil }
        guard (p.count == 4 && p[3] == "article.json") || (p.count == 5 && p[3] == "images" && ReadingArticleCodec.resourceName(p[4])) else { return nil }
        return (profile, article)
    }
    static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    static func check(_ url: URL, directory: Bool, mayBeMissing: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if mayBeMissing && errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw ReadingQueueFailure.storage("The reading queue contains an unsupported file or symbolic link. The original has been kept.")
        }
    }
    static func ensureDirectory(_ url: URL) throws {
        if !exists(url) { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try check(url, directory: true)
    }
    static func prepareRoot(_ directory: URL) throws {
        if !exists(directory) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try check(directory, directory: true)
        try ensureDirectory(root(in: directory))
    }
    static func checkRoot(_ directory: URL) throws {
        try check(directory, directory: true, mayBeMissing: true)
        try check(root(in: directory), directory: true, mayBeMissing: true)
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        try check(url, directory: false)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw ReadingQueueFailure.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ReadingQueueFailure.tooLarge }
        return data
    }
    static func articleFiles(_ url: URL) throws -> [URL] {
        try check(url, directory: true)
        var files: [URL] = []
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            if child.lastPathComponent == "article.json" { try check(child, directory: false); files.append(child) }
            else if child.lastPathComponent == "images" {
                try check(child, directory: true)
                for image in try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                    guard ReadingArticleCodec.resourceName(image.lastPathComponent) else { throw ReadingQueueFailure.invalid("Unexpected saved image filename.") }
                    try check(image, directory: false); files.append(image)
                }
            } else { throw ReadingQueueFailure.invalid("Unexpected file in a saved article. The original has been kept.") }
        }
        return files
    }
    static func ownedNames(in directory: URL) throws -> [String] {
        try checkRoot(directory)
        let queue = root(in: directory)
        guard exists(queue) else { return [] }
        var names: [String] = []
        for profile in try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil) {
            if profile.lastPathComponent == ".staging" { continue }
            guard let id = canonicalUUID(profile.lastPathComponent), id != Profile.incognito.id else { throw ReadingQueueFailure.invalid("Invalid reading queue profile folder.") }
            try check(profile, directory: true)
            for article in try FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) {
                guard canonicalUUID(article.lastPathComponent) != nil else { throw ReadingQueueFailure.invalid("Invalid saved article folder.") }
                for file in try articleFiles(article) {
                    let name = "ReadingQueue/\(profile.lastPathComponent)/\(article.lastPathComponent)/" + (file.deletingLastPathComponent() == article ? file.lastPathComponent : "images/" + file.lastPathComponent)
                    names.append(name)
                }
            }
        }
        return names.sorted()
    }
    static func load(_ url: URL, profileID: UUID, articleID: UUID) throws -> ReadingQueueCandidate {
        let files = try articleFiles(url)
        let article = try ReadingArticleCodec.decode(read(url.appendingPathComponent("article.json"), limit: ReadingArticleCodec.recordLimit), profileID: profileID, articleID: articleID)
        var images: [String: Data] = [:]
        for file in files where file.lastPathComponent != "article.json" { images[file.lastPathComponent] = try read(file, limit: ReadingArticleCodec.imageLimit) }
        let candidate = ReadingQueueCandidate(article: article, images: images)
        try ReadingArticleCodec.validate(candidate)
        return candidate
    }
    static func bytes(_ files: [URL]) throws -> Int64 {
        try files.reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
}
