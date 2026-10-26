import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FaviconHostObservationLifetimeTests: XCTestCase {
    func testUnmountedIconLeafDoesNotRemainOwnedByItsCacheAndCanRemount() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://observer-lifetime.invalid/")!
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)
        try data.write(to: directory.appendingPathComponent(url.host!))
        let cache = Favicons(profileID: profile, fetch: { _ in nil })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        weak var observer: FaviconHostArrival?
        var rendered = false
        var host: NSHostingView<CachedFavicon<SiteIcon>>? = NSHostingView(rootView:
            CachedFavicon(cache: cache, url: url) { image in
                rendered = image != nil
                return SiteIcon(icon: image)
            })
        window.contentView = host
        window.orderFront(nil)
        host?.layoutSubtreeIfNeeded()
        observer = cache.observation(for: url.host!)
        XCTAssertNotNil(observer)
        let ready = ContinuousClock.now + .seconds(5)
        while !rendered, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(rendered)
        window.contentView = nil
        host = nil
        let retired = ContinuousClock.now + .seconds(5)
        while observer != nil, ContinuousClock.now < retired { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(observer, "Keeping the profile cache alive must not retain unmounted host observers")
        rendered = false
        host = NSHostingView(rootView: CachedFavicon(cache: cache, url: url) { image in
            rendered = image != nil
            return SiteIcon(icon: image)
        })
        window.contentView = host
        host?.layoutSubtreeIfNeeded()
        XCTAssertTrue(rendered, "A new leaf must still read the cached artwork after the prior observer retires")
        withExtendedLifetime(cache) {}
    }
}
