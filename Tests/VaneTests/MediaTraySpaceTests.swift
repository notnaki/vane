import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class MediaTraySpaceTests: XCTestCase {
    private func store() -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        addTeardownBlock { @MainActor in
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        return store
    }

    private func height(in store: TabStore) -> CGFloat {
        let renderer = ImageRenderer(content: MediaTrayView().environmentObject(store))
        renderer.proposedSize = ProposedViewSize(width: 250, height: nil)
        return renderer.nsImage?.size.height ?? 0
    }

    func testPausedPlayerRemainsVisibleInAnotherProfileInTheSameWindow() {
        let source = store(), destination = store(), unrelated = store()
        let window = NSWindow(), otherWindow = NSWindow()
        source.parkedIn = window
        destination.window = window
        unrelated.parkedIn = otherWindow
        let player = source.newBlankTab(focus: false)
        MediaState.shared.held.insert(player.id)
        let other = unrelated.newBlankTab(focus: false)
        MediaState.shared.held.insert(other.id)
        defer {
            MediaState.shared.forget(player.id)
            MediaState.shared.forget(other.id)
        }

        XCTAssertGreaterThan(height(in: destination), 0,
                             "Paused media controls follow the window across profile Spaces")
        MediaState.shared.forget(player.id)
        XCTAssertEqual(height(in: destination), 0,
                       "Another window's player must not appear here")
    }

    func testOpeningPlayerInParkedProfileReturnsToItsStashedSpace() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let previous = manager.active
        let sourceProfile = manager.create(name: "Media source")
        let destinationProfile = manager.create(name: "Media destination")
        let sourceSpace = manager.createSpace(name: "Player", in: sourceProfile.id)
        let otherSpace = manager.createSpace(name: "Other", in: sourceProfile.id)
        let destinationSpace = manager.createSpace(name: "Destination", in: destinationProfile.id)
        let owner = Windows.open(profile: sourceProfile, space: sourceSpace, focus: false)
        let window = try XCTUnwrap(owner.window)
        defer {
            window.close()
            _ = manager.delete(sourceProfile.id)
            _ = manager.delete(destinationProfile.id)
            manager.active = previous
        }
        let player = owner.newBlankTab(focus: false)
        player.park(url: URL(string: "https://media.example.test/")!, Parked(title: "Player"))
        owner.current = player.id
        owner.switchTo(space: otherSpace)
        let destination = try XCTUnwrap(Windows.hop(owner, to: destinationSpace))
        XCTAssertTrue(owner.isParked)
        XCTAssertEqual(destination.currentSpaceID, destinationSpace.id)

        XCTAssertTrue(Windows.reveal(player, in: owner))

        XCTAssertTrue(owner.window === window)
        XCTAssertEqual(owner.currentSpaceID, sourceSpace.id)
        XCTAssertEqual(owner.current, player.id)
        XCTAssertTrue(owner.tabs.contains { $0 === player })
    }
}
