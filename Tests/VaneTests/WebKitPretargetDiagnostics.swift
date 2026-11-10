import Darwin
import Foundation
import XCTest

/// Temporary, opt-in observations for the three pretarget cases. No WebKit/AppKit reads.
enum WebKitPretargetDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["VANE_DIAG_WEBKIT_PRETARGET"] == "1"
    private static let observer = IssueObserver()
    private static let installOnce: Void = {
        guard enabled else { return }
        XCTestObservationCenter.shared.addTestObserver(observer)
    }()

    static func installIfEnabled() { _ = installOnce }

    static func emit(_ phase: String) {
        guard enabled else { return }
        var monotonic = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &monotonic)
        let uptime = Double(monotonic.tv_sec) + Double(monotonic.tv_nsec) / 1_000_000_000
        print("WEBKIT_PRETARGET utc=\(Date().timeIntervalSince1970) monotonic=\(uptime) pid=\(getpid()) main=\(Thread.isMainThread) \(phase)")
    }

    private final class IssueObserver: NSObject, XCTestObservation, @unchecked Sendable {
        private func selected(_ test: XCTestCase) -> Bool {
            test.name.contains("BlockerWebKitTests") ||
                test.name.contains("BoostsLibraryTests testGlobalBoostsKeepSameSiteInDifferentProfilesAndSearchProfileNames")
        }

        func testCaseWillStart(_ testCase: XCTestCase) {
            guard selected(testCase) else { return }
            emit("case-start name=\(testCase.name)")
        }

        func testCaseDidFinish(_ testCase: XCTestCase) {
            guard selected(testCase) else { return }
            emit("case-finish name=\(testCase.name)")
        }

        func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
            guard selected(testCase) else { return }
            emit("issue name=\(testCase.name) type=\(issue.type.rawValue) compact=\(issue.compactDescription) detailed=\(issue.detailedDescription ?? "unavailable")")
            if let error = issue.associatedError as NSError? {
                emit("issue-error domain=\(error.domain) code=\(error.code)")
            } else { emit("issue-error unavailable") }
            emit("issue-attachments count=\(issue.attachments.count) payloadPersistence=SecureAttachmentArchiveAttempted")
            let frames = issue.sourceCodeContext.callStack
            emit("issue-stack frameCount=\(frames.count) source=XCTestIssueContext")
            for (index, frame) in frames.enumerated() {
                // Read already-present symbols only; never trigger synchronous symbolication.
                let symbol = frame.symbolInfo
                emit("issue-frame index=\(index) address=\(frame.address) image=\(symbol?.imageName ?? "unavailable") symbol=\(symbol?.symbolName ?? "unavailable")")
            }
            do {
                // Public NSSecureCoding preserves the actual attachment payloads.
                // Failure-only: no archiving, filesystem work or retention on passing paths.
                let archive = try NSKeyedArchiver.archivedData(withRootObject: issue.attachments as NSArray, requiringSecureCoding: true)
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("webkit-pretarget-issues", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent(UUID().uuidString + ".attachments.securearchive")
                try archive.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                emit("issue-archive file=\(file.lastPathComponent) bytes=\(archive.count) attachments=\(issue.attachments.count)")
            } catch { emit("issue-archive unavailable error=\(error)") }
        }
    }
}
