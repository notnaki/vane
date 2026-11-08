import AppKit
import XCTest
@testable import vane

@MainActor final class UpdaterChannelTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "vane-update-channel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "checkForUpdates")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["ETag": "fixture-etag"])!
    }

    func testChannelChangeDiscardsPreviousChannelsResponseAndHeaders() async throws {
        let defaults = try defaults()
        let started = expectation(description: "request started")
        var finish: CheckedContinuation<(Data, URLResponse), Error>?
        var request: URLRequest?
        let updater = Updater(defaults: defaults, fetchRelease: { incoming in
            request = incoming
            started.fulfill()
            return try await withCheckedThrowingContinuation { finish = $0 }
        })
        let task = Task { await updater.fetch(silent: true) }
        await fulfillment(of: [started], timeout: 2)
        defaults.set("nightly", forKey: UpdateChannel.preferenceKey)
        updater.channelChanged()
        let data = Data(#"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[]}"#.utf8)
        finish?.resume(returning: (data, response(try XCTUnwrap(request))))
        await task.value
        XCTAssertNil(defaults.string(forKey: UpdateChannel.stable.cacheKey("tag")))
        XCTAssertNil(defaults.string(forKey: UpdateChannel.stable.cacheKey("etag")))
        XCTAssertNil(defaults.string(forKey: UpdateChannel.nightly.cacheKey("tag")))
        XCTAssertNil(updater.phase)
    }

    func testNightlyUsesItsOwnConditionalCacheAndAccepts304() async throws {
        let defaults = try defaults()
        defaults.set("nightly", forKey: UpdateChannel.preferenceKey)
        defaults.set("stable-only", forKey: UpdateChannel.stable.cacheKey("etag"))
        defaults.set("nightly-only", forKey: UpdateChannel.nightly.cacheKey("etag"))
        var seen: URLRequest?
        let updater = Updater(defaults: defaults, fetchRelease: { request in
            seen = request
            return (Data(), self.response(request, status: 304))
        })
        await updater.fetch(silent: true)
        XCTAssertEqual(seen?.url?.query, "per_page=100")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "If-None-Match"), "nightly-only")
        XCTAssertEqual(defaults.string(forKey: UpdateChannel.stable.cacheKey("etag")), "stable-only")
    }

    func testMalformedReplyDoesNotPoisonConditionalCache() async throws {
        let defaults = try defaults()
        let updater = Updater(defaults: defaults, fetchRelease: { request in
            (Data(#"{"message":"broken response"}"#.utf8), self.response(request))
        })
        await updater.fetch(silent: true)
        XCTAssertNil(defaults.string(forKey: UpdateChannel.stable.cacheKey("etag")))
    }

    func testLegacyBrowserAssetCacheFetchesAndRemembersAPIURL() async throws {
        for channel in UpdateChannel.allCases {
            let defaults = try defaults()
            defaults.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
            defaults.set("old-etag", forKey: "update.\(channel.rawValue).etag")
            defaults.set("old-date", forKey: "update.\(channel.rawValue).lastModified")
            defaults.set("https://github.com/notnaki/vane/releases/download/v1.2.3/Vane.zip",
                         forKey: "update.\(channel.rawValue).asset")
            let release = #"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"Vane.zip","url":"https://api.github.com/repos/notnaki/vane/releases/assets/123","browser_download_url":"https://github.com/notnaki/vane/releases/download/v1.2.3/Vane.zip"}]}"#
            var seen: URLRequest?
            let updater = Updater(defaults: defaults, fetchRelease: { request in
                seen = request
                let body = channel == .stable ? release : "[\(release)]"
                return (Data(body.utf8), self.response(request))
            })
            await updater.fetch(silent: true)
            XCTAssertNil(seen?.value(forHTTPHeaderField: "If-None-Match"))
            XCTAssertNil(seen?.value(forHTTPHeaderField: "If-Modified-Since"))
            XCTAssertEqual(defaults.string(forKey: channel.cacheKey("asset")),
                           "https://api.github.com/repos/notnaki/vane/releases/assets/123")
            XCTAssertEqual(defaults.string(forKey: channel.cacheKey("fallbackAsset")),
                           "https://github.com/notnaki/vane/releases/download/v1.2.3/Vane.zip")
            XCTAssertEqual(defaults.string(forKey: channel.cacheKey("etag")), "fixture-etag")
        }
    }

    func testSwitchingAwayAndBackStillDiscardsOriginalResponse() async throws {
        let defaults = try defaults()
        let started = expectation(description: "original request started")
        var finish: CheckedContinuation<(Data, URLResponse), Error>?
        var request: URLRequest?
        let updater = Updater(defaults: defaults, fetchRelease: { incoming in
            request = incoming
            started.fulfill()
            return try await withCheckedThrowingContinuation { finish = $0 }
        })
        let task = Task { await updater.fetch(silent: true) }
        await fulfillment(of: [started], timeout: 2)
        defaults.set("nightly", forKey: UpdateChannel.preferenceKey)
        updater.channelChanged()
        defaults.set("stable", forKey: UpdateChannel.preferenceKey)
        updater.channelChanged()
        finish?.resume(returning: (Data(#"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[]}"#.utf8),
                                  response(try XCTUnwrap(request))))
        await task.value
        XCTAssertNil(defaults.string(forKey: UpdateChannel.stable.cacheKey("etag")))
        XCTAssertNil(defaults.string(forKey: UpdateChannel.stable.cacheKey("tag")))
    }
}
