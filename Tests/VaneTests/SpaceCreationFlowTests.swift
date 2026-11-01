import XCTest
@testable import vane

@MainActor final class SpaceCreationFlowTests: XCTestCase {
    private func fixture() -> (Profile, Space, TabStore) {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Space creation")
        let space = ProfileManager.shared.createSpace(name: "Existing", in: profile.id)
        let store = TabStore(profileID: profile.id, space: space, session: [])
        addTeardownBlock { @MainActor in
            let owned = store.tabs; TabStore.all.removeAll { $0 === store }; SharedTabs.release(owned)
            _ = ProfileManager.shared.delete(profile.id)
        }
        return (profile, space, store)
    }

    func testOpeningAndCancellingCreationFormDoesNotCreateOrSwitchSpaces() {
        let (profile, space, store) = fixture()
        let tab = store.newBlankTab(focus: false)
        let before = ProfileManager.shared.spaces(for: profile.id)
        store.spacePull = 100
        store.beginCreatingSpace()
        XCTAssertTrue(store.creatingSpace)
        XCTAssertEqual(store.spacePull, 0)
        XCTAssertNil(store.editingSpace)
        XCTAssertEqual(store.currentSpaceID, space.id)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), before)
        XCTAssertTrue(store.tabs.contains { $0.id == tab.id })
        store.cancelCreatingSpace()
        XCTAssertFalse(store.creatingSpace)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), before)
    }

    func testOpeningFormRetiresTheOutgoingSwipePresentationImmediately() {
        let (_, space, store) = fixture()
        store.spaceGesture.monitor.install(store)
        defer { store.spaceGesture.monitor.remove() }
        store.spaceGesture.monitor.track(-30, width: 250, in: store)
        store.spacePull = 2
        XCTAssertTrue(store.spaceSwiping)
        store.beginCreatingSpace()
        XCTAssertTrue(store.creatingSpace)
        XCTAssertFalse(store.spaceSwiping, "The removed sidebar cannot own a return animation behind the form")
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertEqual(store.spacePull, 0)
        store.cancelCreatingSpace()
        XCTAssertEqual(store.currentSpaceID, space.id)
        XCTAssertFalse(store.spaceSwiping, "Cancelling must restore an interactive sidebar")
    }

    func testTemplateFromCreationFormUsesChosenProfileWithoutMakingAnEmptySpace() throws {
        let (profile, source, store) = fixture()
        let target = ProfileManager.shared.create(name: "Template target")
        defer { _ = ProfileManager.shared.delete(target.id) }
        let library = WorkspaceTemplates(manager: .shared)
        let page = SpaceLayout.Page(id: UUID(), url: URL(string: "https://example.test/work")!, kind: .today, title: "Work")
        let layout = SpaceLayout(tabs: [page], pins: Pins(), today: Pins(entries: [.init(row: .tab(page.id.uuidString))]),
                                 splits: [], selected: page.id, omitted: 0)
        _ = try library.save(name: "Work", space: Space(name: "Template", profileID: target.id), layout: layout, unlocked: [])
        store.beginCreatingSpace()
        let sourceBefore = ProfileManager.shared.spaces(for: profile.id)
        let targetBefore = ProfileManager.shared.spaces(for: target.id)
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: target.id, sourceID: source.id, saving: false,
                           creatingSpace: true, sourceProfileID: profile.id, creationName: "Chosen name"), library: library)
        var result: Space?
        model.create(name: "Chosen name") { result = $0 }
        let created = try XCTUnwrap(result, model.message)
        XCTAssertEqual(created.profileID, target.id)
        XCTAssertEqual(created.name, "Chosen name")
        XCTAssertEqual(created.layout?.tabs.first?.url, page.url)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), sourceBefore)
        XCTAssertEqual(ProfileManager.shared.spaces(for: target.id).count, targetBefore.count + 1)
        XCTAssertEqual(store.currentSpaceID, source.id)
    }

    func testCancelledCreationFormCannotLaterCreateATemplateSpace() throws {
        let (profile, source, store) = fixture()
        let library = WorkspaceTemplates(manager: .shared)
        _ = try library.save(name: "Empty", space: source,
            layout: SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil, omitted: 0), unlocked: [])
        store.beginCreatingSpace()
        let model = WorkspaceTemplateModel(store: store,
            request: .init(profileID: profile.id, sourceID: source.id, saving: false,
                           creatingSpace: true, sourceProfileID: profile.id), library: library)
        let before = ProfileManager.shared.spaces(for: profile.id)
        store.cancelCreatingSpace()
        var created = false
        model.create(name: "Rejected") { _ in created = true }
        XCTAssertFalse(created)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile.id), before)
    }
}
