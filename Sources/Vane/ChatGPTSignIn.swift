import AppKit
import CryptoKit
import Foundation
import Network

/// A short-lived listener accepts only the exact loopback OAuth redirect. It never loads
/// sign-in inside Vane's website stores or borrows another application's registration.
@MainActor final class ChatGPTSignIn {
    private var listener: NWListener?
    private(set) var connections: [NWConnection] = []
    private var readDeadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let readTimeout: Duration

    init(readTimeout: Duration = .seconds(5)) { self.readTimeout = readTimeout }
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<ChatGPTOAuth.Pending.Callback, Error>?
    private var pending: ChatGPTOAuth.Pending?
    private var timeout: Task<Void, Never>?
    private var ended = false

    func cancel() { stop(ChatGPTFailure.denied) }
    func run(connection: AIConnection, hostID: String, hint: String?) async throws -> (ChatGPTRegistration, ChatGPTOAuth.Credentials) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)); self?.stop(ChatGPTFailure.timedOut) } catch {}
            }
            defer { stop(CancellationError()) }
            let port = try await start()
            let attempt = try ChatGPTOAuth.Pending(redirectURI: "http://127.0.0.1:\(port)/auth/callback", hostID: hostID,
                                                  registration: connection.registration, idTokenHint: hint)
            pending = attempt
            let result = try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                if !NSWorkspace.shared.open(attempt.authorizationURL) { stop(ChatGPTFailure.invalidCallback) }
            }
            listener?.cancel(); closeConnections()
            let data = try await ChatGPTHTTP.data(attempt.exchange(result), limit: 128000)
            let credentials = try ChatGPTOAuth.grant(data)
            let keys = try await ChatGPTSession.keys()
            let registration = try ChatGPTOAuth.validateIDToken(credentials.idToken, clientID: result.clientID,
                nonce: attempt.nonce, expectedSubject: connection.registration?.subject, jwks: keys)
            try Task.checkCancellation()
            guard !ended else { throw ChatGPTFailure.denied }
            return (registration, credentials)
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue { self.ready?.resume(returning: port); self.ready = nil }
                case .failed:
                    self.stop(ChatGPTFailure.invalidCallback)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.ended, self.connections.count < 8 else { connection.cancel(); return }
                self.connections.append(connection)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    MainActor.assumeIsolated {
                        guard let connection else { return }
                        switch state {
                        case .failed, .cancelled: self?.close(connection)
                        default: break
                        }
                    }
                }
                self.readDeadlines[ObjectIdentifier(connection)] = Task { [weak self, weak connection] in
                    do { try await Task.sleep(for: self?.readTimeout ?? .seconds(5)) } catch { return }
                    if let connection { self?.close(connection) }
                }
                connection.start(queue: .main)
                self.receive(connection, data: Data())
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: .main)
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                guard !self.ended, self.connections.contains(where: { $0 === connection }), error == nil else {
                    self.close(connection); return
                }
                let data = data + (chunk ?? Data())
                guard data.count < 32768 else { self.close(connection); return }
                guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { self.close(connection) } else { self.receive(connection, data: data) }
                    return
                }
                let first = request.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
                guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"),
                      let pending = self.pending, let base = URLComponents(string: pending.redirectURI), let port = base.port,
                      let url = URL(string: "http://127.0.0.1:\(port)" + first[1]) else {
                    self.respond(connection, success: false); return
                }
                do {
                    let result = try pending.callback(url)
                    self.respond(connection, success: true)
                    self.callback?.resume(returning: result); self.callback = nil
                } catch ChatGPTFailure.denied {
                    self.respond(connection, success: false)
                    self.stop(ChatGPTFailure.denied)
                } catch {
                    // An unrelated local request must not consume the real user's attempt.
                    self.respond(connection, success: false)
                }
            }
        }
    }
    private func respond(_ connection: NWConnection, success: Bool) {
        close(connection, response: ChatGPTSignInResponse.data(success: success))
    }
    private func close(_ connection: NWConnection, response: Data? = nil) {
        readDeadlines.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        connection.stateUpdateHandler = nil
        connections.removeAll { $0 === connection }
        if let response {
            // Detach before resuming OAuth so attempt cleanup cannot truncate the reply.
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } else { connection.cancel() }
    }
    private func closeConnections() {
        for connection in connections { close(connection) }
    }
    private func stop(_ error: Error) {
        ended = true
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        closeConnections()
        ready?.resume(throwing: error); ready = nil
        callback?.resume(throwing: error); callback = nil
        pending = nil
    }
}

enum ChatGPTSignInResponse {
    static func data(success: Bool) -> Data {
        // External browsers may refuse to close an app-opened tab. Keep useful copy
        // in that case, and allow only this fixed script rather than arbitrary inline JS.
        let script = "window.close();"
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        let policy = "default-src 'none'" + (success ? "; script-src 'sha256-\(hash)'" : "")
        let body = success ? """
            <!doctype html>
            <html lang="en"><meta charset="utf-8"><title>Return to Vane</title>
            <body><p>ChatGPT authorization received. You can close this tab and return to Vane to finish connecting.</p>
            <script>\(script)</script></body></html>
            """ : "This sign-in request could not be accepted. Return to Vane."
        let type = success ? "text/html" : "text/plain"
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: \(type); charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: \(policy)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        return Data(response.utf8)
    }
}
