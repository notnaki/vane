import AppKit
import XCTest
@testable import vane

@MainActor final class EaselTabTests: XCTestCase {
    func testRealSessionAndSpaceWritersPreserveEaselTabsFoldersAndSelection() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let space = Space(name: "Canvas", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        let board = try repository.create(title: "Saved research")
        let address = EaselAddress.url(board.id)
        let store = TabStore(profileID: profile, space: space, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            EaselStore.forget(profile, directory: Store.directory)
            Store.forget(profile)
        }
        let tab = try XCTUnwrap(store.openEasel(board.id))
        let folder = Folder(name: "Research")
        store.pins.entries = [.init(row: .folder(folder)),
                              .init(row: .tab(tab.id.uuidString), parent: folder.id)]
        XCTAssertTrue(Session.save())
        let savedSpace = try XCTUnwrap(ProfileManager.shared.spaces(for: profile).first)
        XCTAssertEqual(savedSpace.pinnedTabURLs, [address])
        XCTAssertEqual(Spaces.lastTab(in: space.id), address.absoluteString)
        let shape = try XCTUnwrap(TabStore.savedShape(space: space.id, profileID: profile))
        XCTAssertEqual(shape.folder(holding: address.absoluteString)?.id, folder.id)
        let sidecar = Suspension.SpaceState.load(space: space.id, profileID: profile, in: Store.directory)
        XCTAssertEqual(sidecar[address.absoluteString]?.title, board.title)
        let data = try Data(contentsOf: ProfileManager.sessionURL(for: profile, in: Store.directory))
        let entries = try XCTUnwrap(Session.decode(data).first)
        XCTAssertEqual(entries.map(\.url), [address.absoluteString], "An Easel-only window must survive quit")
        XCTAssertEqual(Session.decodeSelected(data).first, tab.id)
        XCTAssertEqual(entries.first?.home, address.absoluteString)
        XCTAssertEqual(entries.first?.kind, .pinned)
        XCTAssertNil(tab.existingWeb)

        TabStore.all.removeAll { $0 === store }
        SharedTabs.release(store.tabs)
        let restored = TabStore(profileID: profile, space: savedSpace, session: entries,
                                selected: tab.id)
        defer {
            TabStore.all.removeAll { $0 === restored }
            SharedTabs.release(restored.tabs)
        }
        XCTAssertEqual(restored.active?.easelID, board.id)
        XCTAssertEqual(restored.active?.title, board.title)
        XCTAssertNil(restored.active?.existingWeb)
        XCTAssertEqual(restored.pins.folder(holding: tab.id.uuidString)?.id, folder.id)
    }

    func testEaselMovesToAnotherSpaceAndSurvivesStashedSpaceSave() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        let board = try repository.create(title: "Move me")
        let address = EaselAddress.url(board.id)
        let store = TabStore(profileID: profile, space: first, session: [])
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            EaselStore.forget(profile, directory: Store.directory)
            Store.forget(profile)
        }
        let tab = try XCTUnwrap(store.openEasel(board.id))
        Spaces.move(tab.id, to: second.id, as: .pinned, from: store)
        XCTAssertFalse(store.tabs.contains { $0.easelID == board.id })
        store.switchTo(space: second)
        let moved = try XCTUnwrap(store.tabs.first { $0.easelID == board.id })
        store.current = moved.id
        XCTAssertEqual(moved.kind, .pinned)
        XCTAssertNil(moved.existingWeb)
        store.switchTo(space: first)
        XCTAssertTrue(store.saveStashedSpace(second.id))
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile).first { $0.id == second.id }?.pinnedTabURLs, [address])
        XCTAssertEqual(Spaces.lastTab(in: second.id), address.absoluteString)
        XCTAssertEqual(Suspension.SpaceState.load(space: second.id, profileID: profile, in: Store.directory)[address.absoluteString]?.title, board.title)
    }

    func testExplicitNavigationLeavesNativeCanvasAndCanReturnToItsPinnedHome() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory) }
        let board = try repository.create()
        let tab = Tab(url: EaselAddress.url(board.id), profileID: profile)
        defer { tab.tearDown() }
        tab.kind = .pinned
        tab.navigate(to: URL(string: "about:blank")!)
        XCTAssertNil(tab.easelSession)
        XCTAssertNotNil(tab.existingWeb)
        tab.navigate(to: EaselAddress.url(board.id))
        XCTAssertEqual(tab.easelID, board.id)
        XCTAssertNil(tab.existingWeb)
    }

    func testOpeningAndRestoringAnEaselKeepsNativeContentAndTheBoardAddress() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory) }
        let board = try repository.create(title: "Research board")
        let address = URL(string: "vane://easel/\(board.id.uuidString)")!
        let tab = Tab(url: address, profileID: profile)
        defer { tab.tearDown() }
        XCTAssertEqual(tab.currentURL, address)
        XCTAssertEqual(tab.title, "Research board")
        XCTAssertNil(tab.existingWeb, "A canvas must not create a WebKit page")

        let restored = Tab(profileID: profile)
        defer { restored.tearDown() }
        restored.kind = .pinned
        restored.restore(url: address, home: address, parked: tab.snapshot)
        restored.resume()
        XCTAssertEqual(restored.currentURL, address)
        XCTAssertEqual(restored.homeURL, address)
        XCTAssertEqual(restored.title, "Research board")
        XCTAssertNil(restored.existingWeb)
        restored.suspend()
        XCTAssertTrue(restored.suspended)
        restored.resume()
        XCTAssertEqual(restored.currentURL, address)
        XCTAssertNil(restored.existingWeb)
    }

    func testBoardRenamesUpdateBothTabAndPinnedSidebarTitle() async throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory) }
        var board = try repository.create(title: "Before")
        let tab = Tab(url: URL(string: "vane://easel/\(board.id.uuidString)")!, profileID: profile)
        defer { tab.tearDown() }
        tab.kind = .pinned
        board.title = "After"
        try repository.save(board)
        await Task.yield()
        XCTAssertEqual(tab.title, "After")
        XCTAssertEqual(TidyTitles.title(for: tab), "After")
        XCTAssertNil(tab.existingWeb)
    }

    func testPrivateTabsCannotOpenPersistentEaselContent() {
        TestEnvironment.prepare()
        let address = URL(string: "vane://easel/\(UUID().uuidString)")!
        let tab = Tab(isPrivate: true, profileID: Profile.incognito.id)
        defer { tab.tearDown() }
        tab.go(address)
        XCTAssertNil(tab.currentURL)
        XCTAssertNil(tab.existingWeb)
    }

    func testCommandPaletteOffersEaselCreationAndLibraryInAnOrdinaryWindow() {
        TestEnvironment.prepare()
        let store = TabStore(session: [])
        defer {
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let commands = Set(PaletteCommand.all(for: store).compactMap(\.command))
        XCTAssertTrue(commands.contains(.newEasel))
        XCTAssertTrue(commands.contains(.showEasels))
    }

    func testNativeCanvasIgnoresWebpageCommandsWithoutCreatingAWebView() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory) }
        let board = try repository.create()
        let store = TabStore(profileID: profile, session: [])
        defer {
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let tab = try XCTUnwrap(store.openEasel(board.id))
        XCTAssertEqual(tab.kind, .pinned)
        XCTAssertEqual(store.current, tab.id)
        XCTAssertFalse(PageCapture.available(tab))
        store.openFind()
        XCTAssertFalse(store.findOpen)
        tab.reload(); tab.hardReload(); tab.back(); tab.forward()
        Zoom.zoomIn(tab); Zoom.reset(tab)
        tab.fillPassword()
        TabAudio.toggleMute(tab)
        let commands = Set(PaletteCommand.all(for: store).compactMap(\.command))
        XCTAssertFalse(commands.contains(.showReader))
        XCTAssertFalse(commands.contains(.capturePage))
        XCTAssertFalse(commands.contains(.reload))
        XCTAssertNil(tab.existingWeb)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertTrue(store.openEasel(board.id) === tab)
        XCTAssertEqual(store.tabs.count, 1)
        store.close(tab.id)
        XCTAssertNotNil(repository.board(board.id), "Closing a pinned canvas must keep the document")
    }

    func testMalformedNativeAddressesAreNotLoadedByWebKit() {
        TestEnvironment.prepare()
        let id = UUID().uuidString
        for raw in ["vane://easel/not-a-board", "vane://easel/\(id)?other=1", "vane://easel/\(id)/extra"] {
            let tab = Tab()
            defer { tab.tearDown() }
            tab.go(URL(string: raw)!)
            XCTAssertNil(tab.currentURL)
            XCTAssertNil(tab.existingWeb)
        }
    }

    func testBoardAddressResolvesOnlyInTheTabsProfile() throws {
        TestEnvironment.prepare()
        let source = UUID(), neighbour = UUID()
        defer {
            EaselStore.forget(source, directory: Store.directory)
            EaselStore.forget(neighbour, directory: Store.directory)
        }
        let board = try EaselStore.shared(profileID: source, directory: Store.directory).create(title: "Private research")
        let tab = Tab(url: EaselAddress.url(board.id), profileID: neighbour)
        defer { tab.tearDown() }
        XCTAssertNil(tab.easelSession?.board)
        XCTAssertNotEqual(tab.title, "Private research")
        XCTAssertNil(tab.existingWeb)
    }

    func testCaptureSavesToChosenBoardWithSourceAndOpensItsNativeTab() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory) }
        let first = try repository.create(title: "First")
        let target = try repository.create(title: "Chosen")
        let store = TabStore(profileID: profile, session: [])
        defer {
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        XCTAssertTrue(EaselWindow.addCapture(image, title: "A useful passage", source: "https://example.com/research",
                                            to: target.id, in: store))
        XCTAssertTrue(repository.board(first.id)?.items.isEmpty == true)
        let item = try XCTUnwrap(repository.board(target.id)?.items.first)
        XCTAssertEqual(item.source, "https://example.com/research")
        XCTAssertEqual(item.text, "A useful passage")
        XCTAssertNotNil(item.image)
        XCTAssertEqual(store.active?.easelID, target.id)
        XCTAssertNil(store.active?.existingWeb)
        let disk = EaselStore(profileID: profile, directory: Store.directory)
        XCTAssertEqual(disk.board(target.id)?.items.first?.source, item.source)

        let privateStore = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === privateStore } }
        XCTAssertFalse(EaselWindow.addCapture(image, title: "Secret", source: "https://example.com/private",
                                             to: target.id, in: privateStore))
        XCTAssertTrue(privateStore.tabs.isEmpty)
        XCTAssertEqual(repository.board(target.id)?.items.count, 1)
    }
}
