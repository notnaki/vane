import AppKit
import XCTest
@testable import vane

@MainActor final class UpdaterOfflineTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "vane-update-offline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func clearToasts() {
        for toast in Toasts.shared.showing { Toasts.shared.dismiss(toast) }
    }

    func testManualOfflineCheckExplainsInternetRequirementAndCanRetry() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        let defaults = try defaults()
        var online = false
        var retried: XCTestExpectation?
        let updater = Updater(defaults: defaults, fetchRelease: { request in
            if !online { throw URLError(.notConnectedToInternet) }
            retried?.fulfill()
            return (Data(#"{"tag_name":"v0.0.0","draft":false,"prerelease":false,"assets":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await updater.fetch(silent: false)
        let notice = try XCTUnwrap(Toasts.shared.queue.latest)
        XCTAssertEqual(notice.text, "You’re offline")
        XCTAssertEqual(notice.action?.title, "Retry")
        guard notice.action?.title == "Retry" else { return }
        let completed = expectation(description: "retry completed")
        retried = completed
        online = true
        Toasts.shared.act(notice)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(Toasts.shared.queue.latest?.text.contains("up to date") == true)
    }

    func testSilentOfflineCheckPreservesCachedReleaseAndExistingNotice() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        let defaults = try defaults()
        let channel = UpdateChannel.stable
        defaults.set("v99.0.0", forKey: channel.cacheKey("tag"))
        defaults.set("https://github.com/notnaki/vane/releases/download/v99.0.0/Vane.zip", forKey: channel.cacheKey("asset"))
        defaults.set("cached-etag", forKey: channel.cacheKey("etag"))
        Toasts.show("Local work saved")
        let id = Toasts.shared.queue.latest?.id
        let updater = Updater(defaults: defaults, fetchRelease: { _ in
            throw URLError(.notConnectedToInternet)
        })
        await updater.fetch(silent: true)
        XCTAssertEqual(Toasts.shared.queue.latest?.id, id)
        XCTAssertNil(updater.phase)
        XCTAssertEqual(defaults.string(forKey: channel.cacheKey("tag")), "v99.0.0")
        XCTAssertEqual(defaults.string(forKey: channel.cacheKey("etag")), "cached-etag")
        XCTAssertEqual(defaults.string(forKey: channel.cacheKey("asset")),
                       "https://github.com/notnaki/vane/releases/download/v99.0.0/Vane.zip")
    }
    func testTransientDownloadFailureOffersRetryButRejectedReleaseDoesNot() {
        XCTAssertEqual(Updater.action(for: .failed(nil))?.title, "Retry")
        XCTAssertEqual(Updater.action(for: .failed("v99.0.0"))?.title, "Releases")
        XCTAssertTrue(Updater.mayArm(tag: "v99.0.0", over: .failed(nil), working: false))
        XCTAssertFalse(Updater.mayArm(tag: "v99.0.0", over: .failed("v99.0.0"), working: false))
    }

    func testConnectionFailuresStayDistinctAndKeepDownloadsRetryable() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        let updater = Updater(defaults: try defaults())
        for (code, message) in [(URLError.notConnectedToInternet, "You’re offline"),
                                (.networkConnectionLost, "Network lost"),
                                (.timedOut, "Timed out")] {
            updater.downloadFailed(URLError(code))
            let phase = try XCTUnwrap(updater.phase)
            XCTAssertEqual(Updater.text(for: phase), message)
            XCTAssertEqual(Toasts.shared.queue.sticky?.action?.title, "Retry")
            XCTAssertTrue(Updater.mayArm(tag: "v99.0.0", over: phase, working: false))
        }
        updater.downloadFailed(URLError(.serverCertificateUntrusted))
        XCTAssertEqual(updater.phase, .failed(nil), "TLS errors must not claim the Mac is offline")
        updater.downloadFailed(NSError(domain: NSPOSIXErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(updater.phase, .failed(nil), "Only URL loading errors identify connectivity failures")
    }

    func testManualCheckDistinguishesConnectionLossTimeoutAndServerFailure() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        for (code, message) in [(URLError.networkConnectionLost, "Network lost"),
                                (.timedOut, "Timed out"),
                                (.serverCertificateUntrusted, "Couldn't check for updates")] {
            let updater = Updater(defaults: try defaults(), fetchRelease: { _ in throw URLError(code) })
            await updater.fetch(silent: false)
            XCTAssertEqual(Toasts.shared.queue.latest?.text, message)
        }
        let updater = Updater(defaults: try defaults(), fetchRelease: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await updater.fetch(silent: false)
        XCTAssertEqual(Toasts.shared.queue.latest?.text, "Couldn't check for updates")
    }

    func testLateOfflineFailureFromPreviousChannelDoesNotShowNotice() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        let defaults = try defaults()
        defaults.set(false, forKey: "checkForUpdates")
        let started = expectation(description: "check started")
        var finish: CheckedContinuation<(Data, URLResponse), Error>?
        let updater = Updater(defaults: defaults, fetchRelease: { _ in
            started.fulfill()
            return try await withCheckedThrowingContinuation { finish = $0 }
        })
        let task = Task { await updater.fetch(silent: false) }
        await fulfillment(of: [started], timeout: 2)
        defaults.set("nightly", forKey: UpdateChannel.preferenceKey)
        updater.channelChanged()
        finish?.resume(throwing: URLError(.notConnectedToInternet))
        await task.value
        XCTAssertNil(Toasts.shared.queue.latest)
    }

    func testRetryAfterChannelSwitchChecksSelectedChannelWhenOfferWasRetired() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        clearToasts()
        defer { clearToasts() }
        let defaults = try defaults()
        defaults.set("nightly", forKey: UpdateChannel.preferenceKey)
        defaults.set(false, forKey: "checkForUpdates")
        let checked = expectation(description: "selected channel checked")
        let updater = Updater(defaults: defaults, fetchRelease: { request in
            XCTAssertEqual(request.url?.path, "/repos/notnaki/vane/releases/latest")
            checked.fulfill()
            throw URLError(.notConnectedToInternet)
        })
        // The old transaction can finish after the channel change. Its retry must
        // still work when channelChanged retired the previous pending offer.
        defaults.set("stable", forKey: UpdateChannel.preferenceKey)
        updater.channelChanged()
        updater.downloadFailed(URLError(.notConnectedToInternet))
        updater.startDownload()
        await fulfillment(of: [checked], timeout: 2)
        XCTAssertEqual(Toasts.shared.queue.latest?.action?.title, "Retry")
    }

}
