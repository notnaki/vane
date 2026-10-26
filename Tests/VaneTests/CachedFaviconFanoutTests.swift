import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import vane

@MainActor final class CachedFaviconFanoutTests: XCTestCase {
    private static let red = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)
    private static let blue = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='blue'/></svg>".utf8)
    private final class Witness {
        var bodies: [String: Int] = [:]
        var images: [String: ObjectIdentifier] = [:]
        func record(_ name: String, _ image: NSImage?) -> SiteIcon {
            bodies[name, default: 0] += 1
            images[name] = image.map(ObjectIdentifier.init)
            return SiteIcon(icon: image)
        }
    }
    private struct Leaves: View {
        let cache: Favicons
        let otherProfile: Favicons
        let a: URL
        let b: URL
        let witness: Witness
        var body: some View {
            HStack {
                CachedFavicon(cache: cache, url: a) { witness.record("a1", $0) }
                CachedFavicon(cache: cache, url: a) { witness.record("a2", $0) }
                CachedFavicon(cache: cache, url: b) { witness.record("b", $0) }
                CachedFavicon(cache: cache, url: nil) { witness.record("nil", $0) }
                CachedFavicon(cache: otherProfile, url: a) { witness.record("other-profile", $0) }
            }
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Actual favicon consumer did not reach the expected state")
                throw NSError(domain: "CachedFaviconFanoutTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    /// Open succeeds only once the real cold disk reader has reached this FIFO.
    /// Withholding bytes then holds A without mocking any cache publication.
    private func admitReader(_ file: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let descriptor = file.path.withCString { Darwin.open($0, O_WRONLY | O_NONBLOCK) }
            if descriptor >= 0 { return descriptor }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "FaviconFIFOReaderNotStarted", code: 1)
    }
    func testHostArrivalUpdatesBothMatchingLeavesWithoutRebuildingUnrelatedOrNilLeaves() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), other = UUID()
        let a = URL(string: "https://arrival-\(UUID().uuidString.lowercased()).invalid/")!
        let b = URL(string: "https://ready-\(UUID().uuidString.lowercased()).invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        let otherDirectory = ProfileManager.faviconDir(for: other, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let blocked = directory.appendingPathComponent(a.host!)
        XCTAssertEqual(blocked.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }, 0)
        try Self.blue.write(to: directory.appendingPathComponent(b.host!))
        try Self.blue.write(to: otherDirectory.appendingPathComponent(a.host!))
        let cache = Favicons(profileID: profile, fetch: { _ in nil })
        let otherCache = Favicons(profileID: other, fetch: { _ in nil })
        let witness = Witness()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 50),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Leaves(cache: cache, otherProfile: otherCache,
                                                a: a, b: b, witness: witness))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var writer = try await admitReader(blocked)
        defer { if writer >= 0 { Darwin.close(writer) } }
        try await waitUntil { witness.images["b"] != nil && witness.images["other-profile"] != nil }
        // Allow B's pending SwiftUI update to finish before establishing the A-only baseline.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(witness.images["a1"])
        XCTAssertNil(witness.images["a2"])
        let before = witness.bodies
        let otherImage = witness.images["other-profile"]
        let written = Self.red.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, $0.count) }
        XCTAssertEqual(written, Self.red.count)
        Darwin.close(writer); writer = -1
        try await waitUntil { witness.images["a1"] != nil && witness.images["a2"] != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(witness.bodies["a1", default: 0], before["a1", default: 0])
        XCTAssertGreaterThan(witness.bodies["a2", default: 0], before["a2", default: 0])
        XCTAssertEqual(witness.images["a1"], witness.images["a2"], "Duplicate host leaves receive the same decoded image")
        XCTAssertEqual(witness.bodies["b"], before["b"], "A host arrival must not rebuild another host's actual CachedFavicon body")
        XCTAssertEqual(witness.bodies["nil"], before["nil"], "A nil-URL leaf must not observe cache-wide arrivals")
        XCTAssertEqual(witness.bodies["other-profile"], before["other-profile"])
        XCTAssertEqual(witness.images["other-profile"], otherImage, "Host identity must remain profile-scoped")
        XCTAssertNotEqual(witness.images["a1"], otherImage)
    }
    func testReusedSlotChangesURLAndProfileAndStopsObservingWhenNil() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), other = UUID()
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        let otherDirectory = ProfileManager.faviconDir(for: other, in: Store.directory)
        for path in [directory, otherDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let a = URL(string: "https://retarget-a.invalid/")!
        let b = URL(string: "https://retarget-b.invalid/")!
        let c = URL(string: "https://retarget-c.invalid/")!
        for url in [a, c] {
            XCTAssertEqual(directory.appendingPathComponent(url.host!).path.withCString {
                mkfifo($0, S_IRUSR | S_IWUSR)
            }, 0)
        }
        try Self.blue.write(to: directory.appendingPathComponent(b.host!))
        try Self.red.write(to: otherDirectory.appendingPathComponent(b.host!))
        let cache = Favicons(profileID: profile, fetch: { _ in nil })
        let otherCache = Favicons(profileID: other, fetch: { _ in nil })
        let witness = Witness()
        func leaf(_ cache: Favicons, _ url: URL?) -> CachedFavicon<SiteIcon> {
            CachedFavicon(cache: cache, url: url) { witness.record("slot", $0) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: leaf(cache, a))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        var writer = try await admitReader(directory.appendingPathComponent(a.host!))
        defer { if writer >= 0 { Darwin.close(writer) } }
        host.rootView = leaf(cache, b)
        host.layoutSubtreeIfNeeded()
        try await waitUntil { witness.images["slot"] != nil }
        try await Task.sleep(for: .milliseconds(50))
        let bImage = witness.images["slot"]
        let beforeOldURL = witness.bodies["slot"]
        let written = Self.red.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, $0.count) }
        XCTAssertEqual(written, Self.red.count)
        Darwin.close(writer); writer = -1
        try await waitUntil { cache.icon(for: a) != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(witness.images["slot"], bImage)
        XCTAssertEqual(witness.bodies["slot"], beforeOldURL,
                       "A reused B slot must unsubscribe from its previous A host")

        host.rootView = leaf(otherCache, b)
        host.layoutSubtreeIfNeeded()
        try await waitUntil { witness.images["slot"] != nil && witness.images["slot"] != bImage }
        XCTAssertTrue(otherCache.icon(for: b).map(ObjectIdentifier.init) == witness.images["slot"],
                      "The same URL in a different profile must replace the image and observer")

        host.rootView = leaf(cache, c)
        host.layoutSubtreeIfNeeded()
        writer = try await admitReader(directory.appendingPathComponent(c.host!))
        try await waitUntil { witness.images["slot"] == nil }
        host.rootView = leaf(cache, nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let beforeNil = witness.bodies["slot"]
        let secondWrite = Self.red.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, $0.count) }
        XCTAssertEqual(secondWrite, Self.red.count)
        Darwin.close(writer); writer = -1
        try await waitUntil { cache.icon(for: c) != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(witness.images["slot"])
        XCTAssertEqual(witness.bodies["slot"], beforeNil,
                       "Retargeting a mounted slot to nil must remove its host subscription")
    }

}
