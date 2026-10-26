import Foundation
import WebKit

/// A session's validated bytes, with no request-time filesystem access.
struct SavedReaderContent: Sendable {
    static let scheme = "vane-saved-reader"
    // The queue bounds JSON + images to 20 MiB. Escaped HTML has a separate bound;
    // it must not make an otherwise valid snapshot exceed a new combined limit.
    private static let htmlLimit = 6 * ReadingArticleCodec.recordLimit + 65_536
    struct Resource: Sendable { let data: Data; let mime: String }
    let document: URL
    private let resources: [String: Resource]

    init(candidate: ReadingQueueCandidate, html: String) throws {
        try ReadingArticleCodec.validate(candidate)
        guard html.utf8.count <= Self.htmlLimit else { throw ReadingQueueFailure.tooLarge }
        document = URL(string: "\(Self.scheme)://\(UUID().uuidString.lowercased())/article.html")!
        var inventory = ["/article.html": Resource(data: Data(html.utf8), mime: "text/html")]
        for resource in candidate.article.resources {
            guard let data = candidate.images[resource.name] else { throw ReadingQueueFailure.invalid("A saved image is missing.") }
            inventory["/images/" + resource.name] = Resource(data: data,
                mime: resource.name.hasSuffix(".png") ? "image/png" : "image/jpeg")
        }
        resources = inventory
    }

    private func path(_ url: URL, allowingFragment: Bool) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == document.host,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              allowingFragment || parts.fragment == nil else { return nil }
        // Compare canonical inventory keys only. Never decode a path or resolve it
        // against a directory; normalized aliases still cannot escape the inventory.
        let path = parts.percentEncodedPath
        guard !path.contains("%"), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return path
    }

    func resource(for request: URLRequest) -> Resource? {
        guard (request.httpMethod ?? "GET") == "GET", let url = request.url,
              let path = path(url, allowingFragment: false) else { return nil }
        return resources[path]
    }

    func allowsNavigation(_ url: URL) -> Bool { path(url, allowingFragment: true) == "/article.html" }
}

@MainActor final class SavedReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private var content: SavedReaderContent?
    private struct Delivery { let task: any WKURLSchemeTask; let id = UUID() }
    private var active: [ObjectIdentifier: Delivery] = [:]
    init(content: SavedReaderContent) { self.content = content; super.init() }

    func allowsNavigation(_ url: URL) -> Bool { content?.allowsNavigation(url) == true }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) { start(urlSchemeTask) }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { stop(urlSchemeTask) }

    func start(_ task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard active[id] == nil else { return }
        let delivery = Delivery(task: task)
        active[id] = delivery
        guard let content, let resource = content.resource(for: task.request), let url = task.request.url else {
            active[id] = nil
            task.didFailWithError(URLError(self.content == nil ? .cancelled : .noPermissionsToReadFile))
            return
        }
        let response = URLResponse(url: url, mimeType: resource.mime,
            expectedContentLength: resource.data.count, textEncodingName: resource.mime == "text/html" ? "utf-8" : nil)
        task.didReceive(response)
        guard active[id]?.id == delivery.id else { return }
        task.didReceive(resource.data)
        guard active[id]?.id == delivery.id else { return }
        active[id] = nil
        task.didFinish()
    }

    func stop(_ task: any WKURLSchemeTask) { active[ObjectIdentifier(task)] = nil }

    func revoke() {
        content = nil
        // Remove each task before calling out. A callback may stop a different task,
        // and a stopped task must never receive another callback, including failure.
        for (id, delivery) in Array(active) {
            guard active[id]?.id == delivery.id else { continue }
            active[id] = nil
            delivery.task.didFailWithError(URLError(.cancelled))
        }
    }
}
