import AppKit
import XCTest
@testable import vane

@MainActor final class SessionSnapshotTests: XCTestCase {
    func testHealthySnapshotReadsOnceAndKeepsAllAlignedMetadata() throws {
        TestEnvironment.prepare()
        let file = URL(fileURLWithPath: "/synthetic/session.json")
        let id = UUID(), space = UUID()
        let entry = Session.Entry(id: id.uuidString, url: "https://snapshot.invalid/current", title: "Saved page",
                                  state: Data([1, 2, 3]).base64EncodedString(), kind: .pinned,
                                  home: "https://snapshot.invalid/home", customName: "Custom", needsRecovery: true)
        let split = Split.Saved(urls: [entry.url, "https://snapshot.invalid/other"], vertical: false, active: 1)
        let data = try XCTUnwrap(Session.encode([[entry], []], splits: [[split], []],
                                               spaces: [space.uuidString, ""], selected: [id.uuidString, nil]))
        var reads: [URL] = []
        let loaded = try XCTUnwrap(Session.load(file, read: { url in reads.append(url); return data }))
        XCTAssertEqual(reads, [file])
        XCTAssertFalse(loaded.recoveringFile)
        XCTAssertEqual(loaded.snapshot.windows, [[entry], []])
        XCTAssertEqual(loaded.snapshot.spaces, [space, nil])
        XCTAssertEqual(loaded.snapshot.selected, [id, nil])
        XCTAssertEqual(loaded.snapshot.splits.first?.first?.urls, split.urls)
        XCTAssertEqual(loaded.snapshot.splits.first?.first?.active, 1)
        XCTAssertTrue(loaded.snapshot.hasIdentityFormat)
    }

    func testDamagedOrMissingPrimaryUsesOneReadPerGenerationAndPausesRecovery() throws {
        TestEnvironment.prepare()
        let file = URL(fileURLWithPath: "/synthetic/session.json")
        let previous = file.appendingPathExtension("previous")
        let entry = Session.Entry(url: "https://snapshot.invalid/recovered")
        let good = try XCTUnwrap(Session.encode([[entry]]))
        for primary in [nil, Data("damaged".utf8), Data(#"{"version":99,"windows":[]}"#.utf8)] as [Data?] {
            var reads: [URL] = []
            let loaded = try XCTUnwrap(Session.load(file, read: { url in
                reads.append(url)
                return url == file ? primary : good
            }))
            XCTAssertEqual(reads, [file, previous])
            XCTAssertTrue(loaded.recoveringFile)
            XCTAssertEqual(loaded.snapshot.windows, [[entry]])
        }
    }

    func testSnapshotKeepsLegacyToleranceEmptyWindowsAndURLOrder() throws {
        TestEnvironment.prepare()
        let file = URL(fileURLWithPath: "/synthetic/session.json")
        let cases = [
            #"[["https://snapshot.invalid/a","https://snapshot.invalid/a"],[],["https://snapshot.invalid/b"]]"#,
            #"{"version":2,"windows":[[{"url":"https://snapshot.invalid/a","kind":"damaged"}]]}"#,
            #"{"version":3,"windows":[[{"url":"https://snapshot.invalid/a"}]],"spaces":[],"selected":[]}"#]
        for text in cases {
            let data = Data(text.utf8)
            let snapshot = try XCTUnwrap(Session.load(file, read: { _ in data })).snapshot
            XCTAssertEqual(snapshot.windows, Session.decode(data))
            XCTAssertEqual(snapshot.spaces, Session.decodeSpaces(data))
            XCTAssertEqual(snapshot.selected, Session.decodeSelected(data))
            XCTAssertFalse(snapshot.hasIdentityFormat)
        }
        let legacy = try XCTUnwrap(Session.load(file, read: { _ in Data(cases[0].utf8) })).snapshot
        XCTAssertEqual(legacy.urls.map(\.absoluteString), ["https://snapshot.invalid/a", "https://snapshot.invalid/b"])
        XCTAssertEqual(legacy.windows.map(\.count), [2, 0, 1])
        var reads = 0
        XCTAssertNil(Session.load(file, read: { _ in reads += 1; return Data(#"{"version":4,"windows":[[{"url":"javascript:bad()"}]]}"#.utf8) }))
        XCTAssertEqual(reads, 2)
        let empty = try XCTUnwrap(Session.encode([]))
        XCTAssertTrue(try XCTUnwrap(Session.load(file, read: { _ in empty })).snapshot.windows.isEmpty)
    }
    func testBatchRestorationPreservesMixedSectionsDuplicateURLsAndAllParkedState() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let space = Space(name: "Batch restore fixture", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let kinds: [TabKind] = [.today, .pinned, .favourite, .today, .pinned]
        let state = Data([1, 2, 3, 4])
        let entries = kinds.enumerated().map { index, kind in
            Session.Entry(id: UUID().uuidString, url: "https://batch.invalid/duplicate",
                          title: "Saved \(index)", state: state.base64EncodedString(), kind: kind,
                          home: kind == .today ? nil : "https://batch.invalid/home-\(index)",
                          customName: "Custom \(index)", needsRecovery: true)
        }
        let selected = try XCTUnwrap(entries[3].id.flatMap(UUID.init(uuidString:)))
        let store = TabStore(profileID: profile, space: space, session: entries, selected: selected)
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            ExtensionHost.forget(profile)
        }
        XCTAssertEqual(store.current, selected)
        XCTAssertEqual(store.tabs.map(\.id.uuidString), [2, 1, 4, 0, 3].compactMap { entries[$0].id })
        XCTAssertEqual(store.pins.tabs, [1, 4].compactMap { entries[$0].id })
        XCTAssertEqual(store.todayShape.tabs, [0, 3].compactMap { entries[$0].id })
        for entry in entries {
            let tab = try XCTUnwrap(store.tabs.first { $0.id.uuidString == entry.id })
            XCTAssertNil(tab.existingWeb)
            XCTAssertTrue(tab.suspended)
            XCTAssertTrue(tab.needsRecovery)
            XCTAssertEqual(tab.snapshot.state, state)
            XCTAssertEqual(tab.snapshot.title, entry.title)
            XCTAssertEqual(tab.workspaceName, entry.customName)
            XCTAssertEqual(tab.currentURL?.absoluteString, entry.url)
            XCTAssertEqual(tab.homeURL?.absoluteString, entry.home)
            XCTAssertEqual(tab.profileID, profile)
        }
    }

}
