import Foundation
import CryptoKit
import ImageIO

enum ReadingQueueFailure: LocalizedError {
    case privateBrowsing, unsupported, staleCapture, missing, futureVersion, tooLarge
    case invalid(String), storage(String)
    var errorDescription: String? {
        switch self {
        case .privateBrowsing: "Offline saving is unavailable in private browsing."
        case .unsupported: "No readable article was found on this page. Try an article page rather than a PDF, app, or sign-in screen."
        case .staleCapture: "The page or profile changed before saving finished. Try saving again."
        case .missing: "This saved article no longer exists."
        case .futureVersion: "This saved article needs a newer version of Vane."
        case .tooLarge: "This article exceeds the offline queue limits. Use a smaller article or remove saved articles and try again."
        case .invalid(let reason), .storage(let reason): reason
        }
    }
}

struct ReadingArticle: Codable, Sendable, Identifiable, Equatable {
    struct Node: Codable, Sendable, Equatable {
        var x: String?; var e: String?; var a: [String: String]?; var c: [Node]?
        init(x: String? = nil, e: String? = nil, a: [String: String]? = nil, c: [Node]? = nil) {
            self.x = x; self.e = e; self.a = a; self.c = c
        }
    }
    struct Resource: Codable, Sendable, Equatable {
        var name: String; var byteCount: Int; var digest: String
        var pixelWidth: Int; var pixelHeight: Int
    }
    var version = 1
    var id = UUID()
    var profileID: UUID
    var title: String
    var sourceURL: String
    var capturedAt = Date.now
    var isRead = false
    var byline = ""
    var nodes: [Node]
    var resources: [Resource] = []
    var missingImages = 0
}

struct ReadingQueueCandidate: Sendable {
    var article: ReadingArticle
    var images: [String: Data]
}

enum ReadingArticleCodec {
    static let recordLimit = 4 * 1024 * 1024
    static let textLimit = 2 * 1024 * 1024
    static let snapshotLimit = 20 * 1024 * 1024
    static let imageLimit = 5 * 1024 * 1024
    static let articleLimit = 1_000
    static let tags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code", "ul", "ol", "li", "figure", "figcaption", "img", "a", "em", "strong", "b", "i", "br", "hr", "sup", "sub", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "th", "td"]
    static func webURL(_ value: String) -> URL? {
        guard value.utf8.count <= 16_384, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func resourceName(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ["png", "jpg"].contains(String(parts[1])),
              let id = UUID(uuidString: String(parts[0])) else { return false }
        return String(parts[0]) == id.uuidString.lowercased()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode(_ article: ReadingArticle) throws -> Data {
        try validateRecord(article)
        let data = try JSONEncoder().encode(article)
        guard data.count <= recordLimit else { throw ReadingQueueFailure.tooLarge }
        return data
    }
    static func decode(_ data: Data, profileID: UUID, articleID: UUID) throws -> ReadingArticle {
        guard data.count <= recordLimit else { throw ReadingQueueFailure.tooLarge }
        // Reject excessively nested JSON before JSONDecoder constructs a recursive tree.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 140 { throw ReadingQueueFailure.tooLarge } }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let article = try JSONDecoder().decode(ReadingArticle.self, from: data)
        guard article.profileID == profileID, article.id == articleID else { throw ReadingQueueFailure.invalid("The article belongs to another profile or entry.") }
        try validateRecord(article)
        return article
    }
    static func validateRecord(_ article: ReadingArticle) throws {
        guard article.version == 1 else { throw ReadingQueueFailure.futureVersion }
        guard article.profileID != Profile.incognito.id, webURL(article.sourceURL) != nil,
              !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              article.title.utf8.count <= 16_384, article.byline.utf8.count <= 16_384,
              article.capturedAt.timeIntervalSince1970.isFinite,
              (0...20).contains(article.missingImages), article.resources.count <= 20,
              Set(article.resources.map(\.name)).count == article.resources.count else { throw ReadingQueueFailure.invalid("Invalid saved article metadata.") }
        for resource in article.resources {
            guard resourceName(resource.name), (1...imageLimit).contains(resource.byteCount),
                  resource.digest.count == 64, resource.digest.allSatisfy({ $0.isHexDigit }),
                  resource.pixelWidth > 0, resource.pixelHeight > 0,
                  resource.pixelWidth <= 40_000_000 / resource.pixelHeight else { throw ReadingQueueFailure.invalid("Invalid saved image metadata.") }
        }
        let images = Set(article.resources.map { "images/" + $0.name })
        var referenced = Set<String>(), stack = article.nodes.map { ($0, 1) }, count = 0, textBytes = 0
        while let (node, depth) = stack.popLast() {
            count += 1
            guard depth <= 64, count <= 50_000 else { throw ReadingQueueFailure.tooLarge }
            if let text = node.x {
                guard node.e == nil, node.a == nil, node.c == nil else { throw ReadingQueueFailure.invalid("Invalid article text node.") }
                textBytes += text.utf8.count
                guard textBytes <= textLimit else { throw ReadingQueueFailure.tooLarge }
                continue
            }
            guard let tag = node.e, tags.contains(tag) else { throw ReadingQueueFailure.invalid("Unsupported saved article markup.") }
            for (key, value) in node.a ?? [:] {
                guard value.utf8.count <= 16_384 else { throw ReadingQueueFailure.tooLarge }
                if tag == "img", key == "src" { guard images.contains(value) else { throw ReadingQueueFailure.invalid("A saved image is missing.") }; referenced.insert(value) }
                else if tag == "img", key == "alt" { continue }
                else if tag == "a", key == "href" {
                    guard webURL(value) != nil || (URL(string: value)?.scheme == "mailto" && !value.contains("\n")) else { throw ReadingQueueFailure.invalid("Invalid article link.") }
                } else { throw ReadingQueueFailure.invalid("Unsupported saved article attribute.") }
            }
            if tag == "img" { guard node.a?["src"] != nil, node.c?.isEmpty != false else { throw ReadingQueueFailure.invalid("Invalid image node.") } }
            stack += (node.c ?? []).map { ($0, depth + 1) }
        }
        guard referenced == images, !plainText(article).isEmpty else { throw ReadingQueueFailure.invalid("The saved article has no readable text or contains unused images.") }
    }
    static func validate(_ candidate: ReadingQueueCandidate) throws {
        let record = try encode(candidate.article)
        guard Set(candidate.images.keys) == Set(candidate.article.resources.map(\.name)) else { throw ReadingQueueFailure.invalid("Saved image files do not match the article.") }
        var remaining = snapshotLimit - record.count
        for resource in candidate.article.resources {
            guard let data = candidate.images[resource.name], data.count == resource.byteCount,
                  data.count <= remaining, digest(data) == resource.digest,
                  let size = rasterSize(data), size.0 == resource.pixelWidth, size.1 == resource.pixelHeight else { throw ReadingQueueFailure.invalid("A saved image is damaged or too large.") }
            remaining -= data.count
        }
    }
    static func rasterSize(_ data: Data) -> (Int, Int)? {
        guard data.count <= imageLimit, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
        return (width, height)
    }
    static func plainText(_ article: ReadingArticle) -> String {
        var parts: [String] = [], stack = article.nodes.reversed().map { $0 }
        while let node = stack.popLast() {
            if let text = node.x { parts.append(text) }
            if let children = node.c { stack += children.reversed() }
            if ["p", "li", "br", "td", "th"].contains(node.e ?? "") { parts.append(" ") }
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func matches(_ article: ReadingArticle, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [article.title, article.sourceURL, article.byline, plainText(article)].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
