import WebKit
import XCTest
@testable import vane

/// Release only disposable normal profiles explicitly recorded by a native fixture.
/// Call after its tabs, windows, extension contexts and observers have been torn down.
@MainActor enum NativeFixtureProfileCleanup {
    static func release(_ profiles: Set<UUID>, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard !profiles.isEmpty else { return }
        guard Store.overrideDirectory != nil else {
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
            await Store.forgetAsync(profile)
            Favicons.forget(profile)
            // Temporary diagnostic control: release fixture owners without erasing
            // or unregistering WebKit backends, to isolate reader file denials.
            ProfileManager.releaseDataStore(for: profile)
        }
    }
}
