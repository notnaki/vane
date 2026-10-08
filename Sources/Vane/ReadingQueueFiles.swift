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
                let images = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
                guard images.count <= 20 else { throw ReadingQueueFailure.tooLarge }
                for image in images {
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
        let record = try read(url.appendingPathComponent("article.json"), limit: ReadingArticleCodec.recordLimit)
        let article = try ReadingArticleCodec.decode(record, profileID: profileID, articleID: articleID)
        let imageFiles = files.filter { $0.lastPathComponent != "article.json" }
        guard Set(imageFiles.map(\.lastPathComponent)) == Set(article.resources.map(\.name)) else {
            throw ReadingQueueFailure.invalid("Saved image files do not match the article.")
        }
        var remaining = ReadingArticleCodec.snapshotLimit - record.count
        let resources = Dictionary(uniqueKeysWithValues: article.resources.map { ($0.name, $0) })
        // Preflight the complete inventory before allocating any image bytes.
        for file in imageFiles {
            let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard let resource = resources[file.lastPathComponent], count == resource.byteCount else { throw ReadingQueueFailure.invalid("A saved image is damaged.") }
            guard count <= remaining else { throw ReadingQueueFailure.tooLarge }
            remaining -= count
        }
        var images: [String: Data] = [:]
        remaining = ReadingArticleCodec.snapshotLimit - record.count
        for file in imageFiles {
            let bytes = try read(file, limit: min(ReadingArticleCodec.imageLimit, remaining))
            remaining -= bytes.count; images[file.lastPathComponent] = bytes
        }
        let candidate = ReadingQueueCandidate(article: article, images: images)
        try ReadingArticleCodec.validate(candidate)
        return candidate
    }
    static func bytes(_ files: [URL]) throws -> Int64 {
        try files.reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
    /// Account for damaged/unrecognized files too, without following links outside the queue.
    static func diskBytes(_ url: URL) throws -> Int64 {
        var stack = [url], bytes: Int64 = 0, count = 0
        while let item = stack.popLast() {
            count += 1; guard count <= 50_000 else { throw ReadingQueueFailure.tooLarge }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if info.st_mode & S_IFMT == S_IFDIR { stack += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) }
            else { bytes += max(0, Int64(info.st_size)) }
        }
        return bytes
    }
    static func validateBackup(files: [String: Data], profileIDs: Set<UUID>) throws -> [UUID: Int] {
        struct Key: Hashable { var profile: UUID; var article: UUID }
        var groups: [Key: [String]] = [:], counts: [UUID: Int] = [:], sources: [UUID: Set<String>] = [:]
        for name in files.keys where name.hasPrefix("ReadingQueue/") {
            guard let identity = parseOwnedName(name), profileIDs.contains(identity.profileID) else { throw ReadingQueueFailure.invalid("A saved article belongs to an unknown profile.") }
            groups[Key(profile: identity.profileID, article: identity.articleID), default: []].append(name)
        }
        for (key, names) in groups {
            let prefix = "ReadingQueue/\(key.profile.uuidString.lowercased())/\(key.article.uuidString.lowercased())/"
            guard let record = files[prefix + "article.json"] else { throw ReadingQueueFailure.invalid("A saved article record is missing.") }
            let article = try ReadingArticleCodec.decode(record, profileID: key.profile, articleID: key.article)
            var images: [String: Data] = [:]
            for name in names where name != prefix + "article.json" { images[URL(fileURLWithPath: name).lastPathComponent] = files[name] }
            try ReadingArticleCodec.validate(.init(article: article, images: images))
            guard sources[key.profile, default: []].insert(article.sourceURL).inserted else { throw ReadingQueueFailure.invalid("This profile contains duplicate saved article URLs.") }
            counts[key.profile, default: 0] += 1
            guard counts[key.profile, default: 0] <= ReadingArticleCodec.articleLimit else { throw ReadingQueueFailure.tooLarge }
        }
        return counts
    }
    static func prepareOwnedParents(_ name: String, in directory: URL) throws {
        guard parseOwnedName(name) != nil else { throw ReadingQueueFailure.invalid("Invalid saved article path.") }
        try check(directory, directory: true)
        var parent = directory
        for component in name.split(separator: "/").dropLast() { parent.appendPathComponent(String(component)); try ensureDirectory(parent) }
    }
    static func removeEmptyDirectories(in directory: URL) throws {
        try checkRoot(directory)
        let queue = root(in: directory)
        guard exists(queue) else { return }
        let fm = FileManager.default
        for profile in try fm.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil) where canonicalUUID(profile.lastPathComponent) != nil {
            try check(profile, directory: true)
            for article in try fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) where canonicalUUID(article.lastPathComponent) != nil {
                try check(article, directory: true)
                let images = article.appendingPathComponent("images")
                if exists(images) { try check(images, directory: true); if try fm.contentsOfDirectory(atPath: images.path).isEmpty { try fm.removeItem(at: images) } }
                if try fm.contentsOfDirectory(atPath: article.path).isEmpty { try fm.removeItem(at: article) }
            }
            if try fm.contentsOfDirectory(atPath: profile.path).isEmpty { try fm.removeItem(at: profile) }
        }
    }
}
