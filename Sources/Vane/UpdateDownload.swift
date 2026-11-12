import Foundation
import Darwin

/// A private, cookie-free transport that owns and meters its destination. URLSession
/// data callbacks are serial, and no body chunk is written until it clears the cap.
final class UpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error { case untrustedURL, invalidResponse, tooLarge, incomplete }

    private let destination: URL
    private let maxBytes: Int64
    private let trusted: @Sendable (URL) -> Bool
    private let progress: @Sendable (Int64, Int64) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private let file: FileHandle
    // Mutable state below belongs to the serial delegate queue after publication.
    // Both attempts share the file, redirect budget and overall deadline.
    private let delegateQueue = OperationQueue()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var timer: DispatchWorkItem?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var redirects = 0
    private var accepted = false
    private var finished = false
    private var failure: Error?
    private var fallbackURL: URL?
    private var retryHTTPFailure = false
    private var cancelled = false
    private var deadline: TimeInterval = 0

    init(destination: URL, maxBytes: Int64, trusted: @escaping @Sendable (URL) -> Bool,
                 progress: @escaping @Sendable (Int64, Int64) -> Void,
                 completion: @escaping @Sendable (Result<URL, Error>) -> Void) throws {
        self.destination = destination
        self.maxBytes = maxBytes
        self.trusted = trusted
        self.progress = progress
        self.completion = completion
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        super.init()
    }

    @discardableResult
    static func start(url: URL, fallbackURL: URL? = nil, destination: URL, maxBytes: Int64, timeout: TimeInterval = 120,
                      trusted: @escaping @Sendable (URL) -> Bool,
                      progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                      completion: @escaping @Sendable (Result<URL, Error>) -> Void) throws -> UpdateDownload {
        guard trusted(url), fallbackURL.map(trusted) ?? true, destination.isFileURL else { throw Failure.untrustedURL }
        guard maxBytes > 0, timeout.isFinite, timeout > 0 else { throw Failure.invalidResponse }
        let operation = try UpdateDownload(destination: destination, maxBytes: maxBytes,
                                           trusted: trusted, progress: progress, completion: completion)
        operation.fallbackURL = fallbackURL == url ? nil : fallbackURL
        operation.deadline = ProcessInfo.processInfo.systemUptime + timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(45, timeout)
        configuration.timeoutIntervalForResource = timeout
        operation.delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: operation.delegateQueue)
        operation.session = session
        // Request timeouts reset with traffic. This independent timer also bounds a
        // slow-drip response and the time spent following redirect hops.
        let timer = DispatchWorkItem { [weak operation] in operation?.cancel() }
        operation.timer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        operation.startTask(url)
        return operation
    }

    func cancel() {
        delegateQueue.addOperation { [self] in
            cancelled = true
            task?.cancel()
        }
    }

    private func startTask(_ url: URL) {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // The asset API otherwise returns JSON metadata with HTTP 200, not the ZIP.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        task = session?.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, trusted(url) else {
            failure = Failure.untrustedURL
            completionHandler(nil)
            task.cancel()
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        next.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // A declined redirect can still deliver its original response before
        // cancellation completes. Preserve its trust failure rather than turning
        // that 302 into a retryable HTTP failure and requesting the fallback.
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, let url = http.url, trusted(url) else {
            failure = Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            retryHTTPFailure = true
            failure = Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = Failure.invalidResponse
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength
        guard expected <= maxBytes else {
            failure = Failure.tooLarge
            completionHandler(.cancel)
            return
        }
        accepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, accepted else { dataTask.cancel(); return }
        guard Int64(data.count) <= maxBytes - received else {
            failure = Failure.tooLarge
            dataTask.cancel()
            return
        }
        do {
            try file.write(contentsOf: data)
            received += Int64(data.count)
            progress(received, expected)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        var outcome = failure ?? error
        if outcome == nil, !accepted || received == 0 || expected >= 0 && received != expected {
            outcome = Failure.incomplete
        }
        let networkFailure = failure == nil && (error == nil ||
            (error as NSError?)?.domain == NSURLErrorDomain && (error as NSError?)?.code != NSURLErrorCancelled)
        if outcome != nil, !cancelled, ProcessInfo.processInfo.systemUptime < deadline,
           retryHTTPFailure || networkFailure, let fallbackURL {
            self.fallbackURL = nil
            do {
                // A partial first response must never be prepended to the fallback ZIP.
                try file.truncate(atOffset: 0)
                try file.seek(toOffset: 0)
                received = 0
                expected = -1
                accepted = false
                failure = nil
                retryHTTPFailure = false
                startTask(fallbackURL)
                return
            } catch { outcome = error }
        }
        finished = true
        timer?.cancel()
        timer = nil
        do { try file.close() } catch { if outcome == nil { outcome = error } }
        if let outcome {
            try? FileManager.default.removeItem(at: destination)
            completion(.failure(outcome))
        } else {
            completion(.success(destination))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
