import Foundation

/// Blocking services and immutable page conversion must never inherit a UI task's executor.
enum NativePageWork {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}

enum ViewSourcePage {
    /// Bounds native input and worst-case escaping to 8 MiB and 48 MiB respectively.
    static let maximumBytes = 8 * 1024 * 1024
    static let script = "(() => { const html = document.documentElement.outerHTML; return html.length <= \(maximumBytes) ? html : null; })()"
    struct TooLarge: LocalizedError {
        var errorDescription: String? { "This page is too large to view its source (8 MB limit)." }
    }

    static func build(_ html: String) throws -> String {
        guard html.utf8.count <= maximumBytes else { throw TooLarge() }
        var output = "<meta charset=utf-8><body style='margin:0'><pre style='font:12px ui-monospace,Menlo,monospace;padding:16px;white-space:pre-wrap;word-break:break-word'>"
        output.reserveCapacity(html.utf8.count + output.utf8.count + 6)
        // One pass and one output allocation; no intermediate full-DOM escaped copies.
        for (offset, scalar) in html.unicodeScalars.enumerated() {
            if offset.isMultiple(of: 65_536) { try Task.checkCancellation() }
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "</pre>"
        return output
    }
}
