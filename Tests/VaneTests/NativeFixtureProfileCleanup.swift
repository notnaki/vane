import WebKit
import XCTest
@testable import vane

/// Release only disposable normal profiles explicitly recorded by a native fixture.
/// Call after its tabs, windows, extension contexts and observers have been torn down.
@MainActor enum NativeFixtureProfileCleanup {
    static func release(_ profiles: Set<UUID>, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard !profiles.isEmpty else { return }
        guard let directory = Store.overrideDirectory else {
            XCTFail("Native fixture profile cleanup requires an isolated data directory", file: file, line: line)
            return
        }
        for profile in profiles {
            guard profile != ProfileManager.defaultID, profile != Profile.incognito.id else {
                XCTFail("Native fixture cleanup refuses default and incognito profiles", file: file, line: line)
                continue
            }
            // The normal profile's cached extension controller also owns its named store.
            ExtensionHost.forget(profile)
            var store: WKWebsiteDataStore? = ProfileManager.dataStore(for: profile)
            await store!.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            store = nil
            ProfileManager.releaseDataStore(for: profile)
            let identifier = try XCTUnwrap(ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: directory), file: file, line: line)
            let error: Error? = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: identifier) { continuation.resume(returning: $0) }
            }
            if let error {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, "WKWebSiteDataStore", file: file, line: line)
                XCTAssertEqual(failure.code, 1, "Unexpected native fixture unregister failure: \(error)", file: file, line: line)
                print("Native fixture \(identifier): contents erased and cache released; WebKit still has the empty store in use.")
            }
        }
    }
}
