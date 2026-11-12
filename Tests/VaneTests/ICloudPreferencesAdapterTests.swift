import Foundation
import WebKit
import Synchronization
import XCTest
@testable import vane

final class ICloudPreferencesAdapterTests: XCTestCase {
    @MainActor private func fixture(_ body: @MainActor (URL, UserDefaults, UUID) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-preferences-\(UUID())")
        let suite = "icloud-preferences-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.dropScratchSuite(suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await body(root, defaults, UUID())
    }

    @MainActor func testAllowlistedSettingsMergeIndependentlyAndNeverExportSecurityState() async throws {
        try await fixture { root, defaults, profile in
            defaults.set(24, forKey: "readerFontSize")
            defaults.set(false, forKey: "readerSerif")
            defaults.set("duckduckgo", forKey: "searchEngine")
            for key in ["extensionConsent.v1", "extensionBookmarks", "sitePermission.v2.camera", "downloadDirectory", "iCloud.masterEnabled", "AIKeys", "unknownFuturePreference"] {
                defaults.set("secret", forKey: key)
            }
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            let captured = try await adapter.capture([.readerPreferences, .search])
            XCTAssertEqual(Set(captured.map(\.id)), ["readerFontSize", "readerSerif", "searchEngine"])
            defaults.set(17, forKey: "readerFontSize")
            defaults.set(true, forKey: "readerSerif")
            try await adapter.apply(captured.filter { $0.id == "readerFontSize" }, deleted: [], enabled: [.readerPreferences])
            XCTAssertEqual(defaults.integer(forKey: "readerFontSize"), 24)
            XCTAssertTrue(defaults.bool(forKey: "readerSerif"))
            let poison = ICloudItem(category: .search, id: "extensionConsent.v1", profileID: nil, parentID: nil,
                                   fields: ["value": try PropertyListSerialization.data(fromPropertyList: "poison", format: .binary, options: 0)])
            try await adapter.apply([poison], deleted: [], enabled: [.search])
            XCTAssertEqual(defaults.string(forKey: "extensionConsent.v1"), "secret")
        }
    }

    @MainActor func testDisabledCategoriesAndPrivateOrUnknownProfilesCannotMutateSettings() async throws {
        try await fixture { root, defaults, profile in
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile, Profile.incognito.id] })
            let value = try PropertyListSerialization.data(fromPropertyList: 1.5, format: .binary, options: 0)
            let host = try PropertyListSerialization.data(fromPropertyList: "example.com", format: .binary, options: 0)
            let rows = [profile, Profile.incognito.id, UUID()].map {
                ICloudItem(category: .siteSettings, id: $0.uuidString.lowercased() + "/siteZoom/" + ICloudIdentity.digest("example.com"), profileID: $0, parentID: nil, fields: ["host": host, "value": value])
            }
            try await adapter.apply(rows, deleted: [], enabled: [])
            XCTAssertNil(defaults.object(forKey: ProfileManager.defaultsKey("siteZoom", profile)))
            try await adapter.apply(rows, deleted: [], enabled: [.siteSettings])
            XCTAssertEqual(defaults.dictionary(forKey: ProfileManager.defaultsKey("siteZoom", profile))?["example.com"] as? Double, 1.5)
            XCTAssertNil(defaults.object(forKey: ProfileManager.defaultsKey("siteZoom", Profile.incognito.id)))
            let captured = try await adapter.capture([.siteSettings])
            XCTAssertEqual(captured.map(\.profileID), [profile])
        }
    }

    @MainActor func testSiteSettingImportAndDeletionPreserveOtherHosts() async throws {
        try await fixture { root, defaults, profile in
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            let key = ProfileManager.defaultsKey("siteZoom", profile)
            defaults.set(["example.com": 1.5], forKey: key)
            let captured = try await adapter.capture([.siteSettings])
            defaults.set(["other.example": 0.75], forKey: key)
            try await adapter.apply(captured, deleted: [], enabled: [.siteSettings])
            XCTAssertEqual(defaults.dictionary(forKey: key) as? [String: Double], ["example.com": 1.5, "other.example": 0.75])
            try await adapter.apply([], deleted: captured, enabled: [.siteSettings])
            XCTAssertEqual(defaults.dictionary(forKey: key) as? [String: Double], ["other.example": 0.75])
        }
    }

    @MainActor func testShortcutPayloadDropsUnknownFieldsAndUnknownActions() async throws {
        try await fixture { root, defaults, profile in
            let binding = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Keybinding("x")))
            let table: [String: Any] = ["bindings": ["unknownAction": binding],
                "priorities": [:], "migrated": 2, "securityScopedBookmark": "secret"]
            defaults.set(try JSONSerialization.data(withJSONObject: table), forKey: "keybindings.v1")
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            let rows = try await adapter.capture([.keyboardShortcuts])
            let plist = try PropertyListSerialization.propertyList(from: XCTUnwrap(rows.first?.fields["value"]), format: nil)
            let blob = try XCTUnwrap(plist as? Data)
            let portable = try XCTUnwrap(JSONSerialization.jsonObject(with: blob) as? [String: Any])
            XCTAssertNil(portable["securityScopedBookmark"])
            XCTAssertTrue((portable["bindings"] as? [String: Any] ?? [:]).isEmpty)
        }
    }

    @MainActor func testExtensionPackageArrivesDisabledWithoutPermissionsPathsOrRuntimeData() async throws {
        try await fixture { root, defaults, profile in
            let sourceRoot = root.appendingPathComponent("source")
            let targetRoot = root.appendingPathComponent("target")
            let source = sourceRoot.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Portable","version":"1","permissions":["storage","tabs"]}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
            try Data("console.log('portable');".utf8).write(to: source.appendingPathComponent("code.js"))
            let store = ExtensionCodeStore(profileID: profile, directory: sourceRoot)
            let stage = try store.stage(source)
            let record = ExtensionCodeStore.Record(identity: UUID().uuidString, revision: stage.revision,
                sourcePath: "/private/local/source", name: "Portable", version: "1", summary: "",
                required: .init(permissions: ["storage", "tabs"], sites: []), optional: .init(permissions: [], sites: []), compatibility: [])
            try store.save([source.path: record])
            defaults.set([source.path: "local-grant"], forKey: ProfileManager.defaultsKey("extensionConsent.v1", profile))
            defaults.set(["vault": "local-secret"], forKey: "extension.storage.local")
            let sender = ICloudPreferencesAdapter(directory: sourceRoot, defaults: defaults, profileIDs: { [profile] })
            let captured = try await sender.capture([.extensions])
            XCTAssertEqual(captured.count, 1)
            let portable = try XCTUnwrap(captured.first).decode(ICloudPreferencesAdapter.ExtensionPackage.self)
            XCTAssertEqual(Set(portable.resources.keys), ["manifest.json", "code.js"])
            let wire = try JSONEncoder().encode(captured)
            XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("/private/local/source"))
            let receiver = ICloudPreferencesAdapter(directory: targetRoot, defaults: defaults, profileIDs: { [profile] })
            try await receiver.apply(captured, deleted: [], enabled: [.extensions])
            let imported = try ExtensionCodeStore(profileID: profile, directory: targetRoot).records()
            let installation = try XCTUnwrap(imported.first)
            XCTAssertEqual(installation.value.identity.lowercased(), record.identity.lowercased())
            XCTAssertTrue((defaults.stringArray(forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile)) ?? []).contains(installation.key))
            XCTAssertNil(ExtensionConsent.saved(for: URL(fileURLWithPath: installation.key), profileID: profile, in: defaults))
            XCTAssertNil(installation.value.nativeMessagingErrorCompatibilityVersion)
            XCTAssertEqual(try Data(contentsOf: ExtensionCodeStore(profileID: profile, directory: targetRoot).code(for: installation.value).appendingPathComponent("code.js")), Data("console.log('portable');".utf8))
        }
    }

    @MainActor func testDamagedAndTraversalPackagesAreRejectedBeforeInstallation() async throws {
        try await fixture { root, defaults, profile in
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            for path in ["../escape", "/absolute", "code.js"] {
                let package = ICloudPreferencesAdapter.ExtensionPackage(identity: UUID().uuidString,
                    resources: [path: Data("code".utf8)], digests: [path: String(repeating: "0", count: 64)], safari: nil, storeID: nil)
                let item = ICloudItem(category: .extensions, id: profile.uuidString.lowercased() + "/" + package.identity.lowercased(), profileID: profile, parentID: nil,
                                      fields: try ICloudItem.encodedFields(package))
                do { try await adapter.apply([item], deleted: [], enabled: [.extensions]); XCTFail("Invalid package was admitted") }
                catch { }
            }
            XCTAssertTrue(try ExtensionCodeStore(profileID: profile, directory: root).records().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        }
    }

    @MainActor func testSafariSourceRequiresItsVerifiedLocallyInstalledHost() async throws {
        try await fixture { root, defaults, profile in
            let source = SafariExtensionSource(appBundleID: "invalid.vane.icloud.missinghost",
                extensionBundleID: "invalid.vane.icloud.missinghost.extension", teamID: "AAAAAAAAAA",
                appPath: "/Applications/CloudOnlyMissingHost.app", signatureHash: String(repeating: "a", count: 64))
            let package = ICloudPreferencesAdapter.ExtensionPackage(identity: UUID().uuidString,
                resources: [:], digests: [:], safari: .init(source), storeID: nil)
            let item = ICloudItem(category: .extensions,
                id: profile.uuidString.lowercased() + "/" + package.identity.lowercased(), profileID: profile,
                parentID: nil, fields: try ICloudItem.encodedFields(package))
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            do { try await adapter.apply([item], deleted: [], enabled: [.extensions]); XCTFail("A remote descriptor cannot replace an installed Safari host") }
            catch { XCTAssertTrue(error.localizedDescription.contains("installed app")) }
            XCTAssertTrue(try ExtensionCodeStore(profileID: profile, directory: root).records().isEmpty)
        }
    }

    @MainActor func testIncomingOversizedPreferenceRetainsCurrentValue() async throws {
        try await fixture { root, defaults, profile in
            defaults.set("google", forKey: "searchEngine")
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            let item = ICloudItem(category: .search, id: "searchEngine", profileID: nil, parentID: nil,
                fields: ["value": Data(repeating: 0, count: ICloudLimits.inlineBytes + 1)])
            do { try await adapter.apply([item], deleted: [], enabled: [.search]); XCTFail("Oversize input must not overwrite a setting") }
            catch { }
            XCTAssertEqual(defaults.string(forKey: "searchEngine"), "google")
        }
    }

    @MainActor private final class ParserGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { continuation?.resume(); continuation = nil }
        func waitUntilEntered() async throws {
            let deadline = Date().addingTimeInterval(5)
            while !entered {
                guard Date() < deadline else { throw ICloudFailure.invalid("The parser did not start before its test deadline.") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @MainActor private func packageItem(profile: UUID, identity: String = UUID().uuidString,
                                        code: String = "remote code") throws -> ICloudItem {
        let resources = ["manifest.json": Data(#"{"manifest_version":3,"name":"Portable","version":"1","permissions":["storage"]}"#.utf8),
                         "code.js": Data(code.utf8)]
        let package = ICloudPreferencesAdapter.ExtensionPackage(identity: identity.lowercased(), resources: resources,
            digests: resources.mapValues { ICloudIdentity.digest(String(decoding: $0, as: UTF8.self)) }, safari: nil, storeID: nil)
        return ICloudItem(category: .extensions,
            id: profile.uuidString.lowercased() + "/" + identity.lowercased(), profileID: profile, parentID: nil,
            fields: try ICloudItem.encodedFields(package))
    }

    @MainActor func testChildOnlySitePreferenceCreatesOnlyAnOpaqueMissingProfile() async throws {
        try await fixture { root, defaults, profile in
            var profiles: [UUID] = []
            var ensured: [UUID] = []
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { profiles },
                ensureProfile: { id in ensured.append(id); profiles.append(id) })
            let item = ICloudItem(category: .siteSettings,
                id: profile.uuidString.lowercased() + "/siteZoom/" + ICloudIdentity.digest("example.com"),
                profileID: profile, parentID: nil, fields: [
                    "host": try PropertyListSerialization.data(fromPropertyList: "example.com", format: .binary, options: 0),
                    "value": try PropertyListSerialization.data(fromPropertyList: 1.5, format: .binary, options: 0)])
            try await adapter.apply([item], deleted: [], enabled: [.siteSettings])
            XCTAssertEqual(ensured, [profile])
            XCTAssertEqual(profiles, [profile])
            XCTAssertEqual(defaults.dictionary(forKey: ProfileManager.defaultsKey("siteZoom", profile))?["example.com"] as? Double, 1.5)
            let privateItem = ICloudItem(category: .siteSettings, id: item.id, profileID: Profile.incognito.id,
                parentID: nil, fields: item.fields)
            do { try await adapter.apply([privateItem], deleted: [], enabled: [.siteSettings]) } catch { }
            XCTAssertEqual(ensured, [profile], "Private identities must never reach placeholder creation")
        }
    }

    @MainActor func testLocalPreferenceEditDuringExtensionParsingSurvivesIncomingApply() async throws {
        try await fixture { root, defaults, profile in
            defaults.set(17, forKey: "readerFontSize")
            let gate = ParserGate()
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] },
                parseExtension: { url in await gate.hold(); return try await WKWebExtension(resourceBaseURL: url) })
            let baseline = try await adapter.capture([.readerPreferences, .extensions])
            let preference = ICloudItem(category: .readerPreferences, id: "readerFontSize", profileID: nil,
                parentID: nil, fields: ["value": try PropertyListSerialization.data(fromPropertyList: 24, format: .binary, options: 0)])
            let package = try packageItem(profile: profile)
            let task = Task { @MainActor in
                try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })) {
                    try await adapter.apply([preference, package], deleted: [], enabled: [.readerPreferences, .extensions])
                }
            }
            defer { gate.open() }
            try await gate.waitUntilEntered()
            defaults.set(20, forKey: "readerFontSize")
            gate.open()
            try await task.value
            XCTAssertEqual(defaults.integer(forKey: "readerFontSize"), 20)
        }
    }

    @MainActor func testLocalExtensionRevisionChangedWhileParserHeldSurvivesRemoteUpdate() async throws {
        try await fixture { root, defaults, profile in
            let identity = UUID().uuidString.lowercased()
            let initial = try packageItem(profile: profile, identity: identity, code: "initial code")
            let receiver = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            try await receiver.apply([initial], deleted: [], enabled: [.extensions])
            let baseline = try await receiver.capture([.extensions])
            let incoming = try packageItem(profile: profile, identity: identity, code: "remote update")
            let gate = ParserGate()
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] },
                parseExtension: { url in await gate.hold(); return try await WKWebExtension(resourceBaseURL: url) })
            let task = Task { @MainActor in
                try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })) {
                    try await adapter.apply([incoming], deleted: [], enabled: [.extensions])
                }
            }
            defer { gate.open() }
            try await gate.waitUntilEntered()
            let store = ExtensionCodeStore(profileID: profile, directory: root)
            var records = try store.records()
            let current = try XCTUnwrap(records.first)
            let localSource = root.appendingPathComponent("local-edit")
            try FileManager.default.createDirectory(at: localSource, withIntermediateDirectories: true)
            let resources = try store.resources(in: store.code(for: current.value))
            for (path, data) in resources { try data.write(to: localSource.appendingPathComponent(path)) }
            try Data("local update".utf8).write(to: localSource.appendingPathComponent("code.js"))
            let localStage = try store.stage(localSource)
            var revised = current.value
            revised.revision = localStage.revision
            records[current.key] = revised
            try store.save(records)
            gate.open()
            try await task.value
            let retained = try XCTUnwrap(store.records()[current.key])
            XCTAssertEqual(retained.revision, localStage.revision)
            XCTAssertEqual(try Data(contentsOf: store.code(for: retained).appendingPathComponent("code.js")), Data("local update".utf8))
        }
    }

    @MainActor func testAdmissionRevocationWhileParserHeldPreventsExtensionCommit() async throws {
        try await fixture { root, defaults, profile in
            let gate = ParserGate(), admission = ICloudAdmission()
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] },
                parseExtension: { url in await gate.hold(); return try await WKWebExtension(resourceBaseURL: url) })
            let package = try packageItem(profile: profile)
            let task = Task { @MainActor in
                try await ICloudApplyContext.$admission.withValue(admission) {
                    try await adapter.apply([package], deleted: [], enabled: [.extensions])
                }
            }
            defer { gate.open() }
            try await gate.waitUntilEntered()
            admission.revoke()
            gate.open()
            do { try await task.value; XCTFail("Revoked import must not commit") } catch { }
            XCTAssertTrue(try ExtensionCodeStore(profileID: profile, directory: root).records().isEmpty)
            XCTAssertNil(defaults.object(forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile)))
        }
    }

    @MainActor func testProfileRetiredWhileParserHeldIsNotRecreated() async throws {
        try await fixture { root, defaults, profile in
            let gate = ParserGate()
            var profiles = [profile]
            var retired = false
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { profiles },
                ensureProfile: { id in
                    guard !retired else { throw CancellationError() }
                    if !profiles.contains(id) { profiles.append(id) }
                }, parseExtension: { url in await gate.hold(); return try await WKWebExtension(resourceBaseURL: url) })
            let package = try packageItem(profile: profile)
            let task = Task { @MainActor in try await adapter.apply([package], deleted: [], enabled: [.extensions]) }
            defer { gate.open() }
            try await gate.waitUntilEntered()
            retired = true; profiles = []
            gate.open()
            do { try await task.value; XCTFail("A retired profile must not be recreated by an old import") } catch { }
            XCTAssertTrue(profiles.isEmpty)
            XCTAssertTrue(try ExtensionCodeStore(profileID: profile, directory: root).records().isEmpty)
        }
    }

    @MainActor func testExtensionSnapshotWorkerKeepsMainActorResponsive() async throws {
        try await fixture { root, defaults, profile in
            let entered = Mutex(false)
            let gate = DispatchSemaphore(value: 0)
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] },
                readExtensions: { _, _ in
                    entered.withLock { $0 = true }
                    guard gate.wait(timeout: .now() + 5) == .success else {
                        throw ICloudFailure.invalid("Snapshot worker blocked the main actor past the test deadline.")
                    }
                    return []
                })
            let task = Task { @MainActor in try await adapter.capture([.extensions]) }
            defer { gate.signal() }
            let deadline = Date().addingTimeInterval(3)
            while !entered.withLock({ $0 }) {
                guard Date() < deadline else { throw ICloudFailure.invalid("Snapshot worker did not enter before the test deadline.") }
                try await Task.sleep(for: .milliseconds(1))
            }
            // Reaching this actor turn before releasing disk work proves the UI is live.
            gate.signal()
            let rows = try await task.value
            XCTAssertTrue(rows.isEmpty)
        }
    }

    @MainActor func testExtensionSyncDataHasOneSeparateCategoryOwner() async throws {
        try await fixture { root, defaults, profile in
            let adapter = ICloudPreferencesAdapter(directory: root, defaults: defaults, profileIDs: { [profile] })
            XCTAssertFalse(adapter.categories.contains(.extensionSyncData))
            let rows = try await adapter.capture([.extensionSyncData])
            XCTAssertTrue(rows.isEmpty)
        }
    }
}
