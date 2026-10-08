import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ReadingQueueImageResult: Sendable {
    var resources: [ReadingArticle.Resource] = []
    var images: [String: Data] = [:]
    var mapping: [String: String] = [:]
    var missingCount = 0
}
protocol ReadingQueueImageLoading: Sendable {
    func collect(urls: [URL]) async -> ReadingQueueImageResult
}

struct ReadingQueueImages: ReadingQueueImageLoading {
    struct Raster { var resource: ReadingArticle.Resource; var data: Data }
    static func allowedRedirect(_ url: URL, count: Int) -> Bool { count <= 5 && ReadingArticleCodec.webURL(url.absoluteString) != nil }
    static func raster(_ bytes: Data) -> Raster? {
        guard bytes.count <= ReadingArticleCodec.imageLimit,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "public.webp", "public.heic"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 40_000_000 / h,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= ReadingArticleCodec.imageLimit else { return nil }
        let output = data as Data
        return Raster(resource: .init(name: UUID().uuidString.lowercased() + ".png", byteCount: output.count,
            digest: ReadingArticleCodec.digest(output), pixelWidth: w, pixelHeight: h), data: output)
    }
    func collect(urls: [URL]) async -> ReadingQueueImageResult {
        var result = ReadingQueueImageResult(), seen = Set<String>()
        let unique = urls.filter { seen.insert($0.absoluteString).inserted }
        let deadline = ContinuousClock.now + .seconds(60)
        var remaining = ReadingArticleCodec.snapshotLimit - ReadingArticleCodec.recordLimit
        for (index, url) in unique.enumerated() {
            guard index < 20, !Task.isCancelled, ContinuousClock.now < deadline else {
                result.missingCount = min(20, result.missingCount + unique.count - index); break
            }
            do {
                let time = min(15.0, Double(ContinuousClock.now.duration(to: deadline).components.seconds))
                let data = try await Self.download(url, timeout: max(0.1, time))
                if let raster = Self.raster(data), raster.data.count <= remaining {
                    remaining -= raster.data.count
                    result.resources.append(raster.resource)
                    result.images[raster.resource.name] = raster.data
                    result.mapping[url.absoluteString] = "images/" + raster.resource.name
                } else { result.missingCount += 1 }
            } catch { result.missingCount += 1 }
        }
        return result
    }
    static func download(_ url: URL, timeout: Double = 15) async throws -> Data {
        guard ReadingArticleCodec.webURL(url.absoluteString) != nil else { throw ReadingQueueFailure.unsupported }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let delegate = ReadingImageRedirects()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var request = URLRequest(url: url); request.httpShouldHandleCookies = false
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      response.expectedContentLength <= ReadingArticleCodec.imageLimit else { throw ReadingQueueFailure.unsupported }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= ReadingArticleCodec.imageLimit { throw ReadingQueueFailure.tooLarge }
                    try Task.checkCancellation(); data.append(byte)
                }
                return data
            }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private final class ReadingImageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard let url = request.url, ReadingQueueImages.allowedRedirect(url, count: count) else { completionHandler(nil); return }
        var clean = request; clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie"); clean.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
