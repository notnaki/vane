import Foundation
import WebKit

/// WebKit can record a background evaluation failure without ever invoking its
/// completion handler. Own the continuation separately from that callback: neither
/// cancellation nor the deadline may wait for a non-cooperating WebKit operation.
@MainActor enum ExtensionBackgroundStartup {
    static func load(_ context: WKWebExtensionContext,
                     checkLifetime: @escaping @MainActor () throws -> Void) async throws {
        try await wait(start: { completion in
            context.loadBackgroundContent { error in
                Task { @MainActor in completion(error) }
            }
        }, check: {
            try checkLifetime()
            let errors = ExtensionDiagnostics.blockingErrors(context.errors, manifest: context.webExtension.manifest)
            guard errors.isEmpty else { throw ExtensionHost.Failure(ExtensionDiagnostics.describe(errors)) }
        })
    }

    static func wait(timeout: Duration = .seconds(10), pollInterval: Duration = .milliseconds(50),
                     start: (@escaping @MainActor @Sendable (Error?) -> Void) -> Void,
                     check: @escaping @MainActor () throws -> Void) async throws {
        let attempt = Attempt()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                attempt.continuation = continuation
                attempt.check = check
                do { try check() }
                catch { attempt.finish(.failure(error)); return }
                attempt.monitor = Task { [weak attempt] in
                    let deadline = ContinuousClock.now + timeout
                    do {
                        while !Task.isCancelled {
                            try attempt?.check?()
                            guard ContinuousClock.now < deadline else {
                                throw ExtensionHost.Failure("The extension’s background content did not finish loading. Choose Retry or Update from Folder to repair the extension.")
                            }
                            try await Task.sleep(for: pollInterval)
                        }
                    } catch { attempt?.finish(.failure(error)) }
                }
                start { [weak attempt] error in attempt?.complete(error) }
            }
        } onCancel: {
            Task { @MainActor in attempt.finish(.failure(CancellationError())) }
        }
    }

    @MainActor private final class Attempt {
        var continuation: CheckedContinuation<Void, Error>?
        var monitor: Task<Void, Never>?
        var check: (@MainActor () throws -> Void)?

        func complete(_ error: Error?) {
            guard continuation != nil else { return }
            do {
                if let error { throw error }
                try check?()
                finish(.success(()))
            } catch { finish(.failure(error)) }
        }

        func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            check = nil
            monitor?.cancel()
            monitor = nil
            continuation.resume(with: result)
        }
    }
}
