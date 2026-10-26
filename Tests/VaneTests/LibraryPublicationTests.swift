import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class LibraryPublicationTests: XCTestCase {
    @MainActor private final class Publications {
        var values: [String: Int] = [:]
        var subscriptions: [AnyCancellable] = []
        init(store: TabStore) {
            let library = Library.shared
            func observe<P: Publisher>(_ publisher: P, _ key: String) where P.Failure == Never {
                subscriptions.append(publisher.dropFirst().sink { [weak self] _ in
                    self?.values[key, default: 0] += 1
                })
            }
            observe(store.$libraryOpen, "open")
            observe(store.$findOpen, "find")
            observe(library.$section, "section")
            observe(library.$query, "query")
            observe(library.$littleArcOnly, "little")
            observe(library.$completedOnly, "completed")
            observe(library.$focusToken, "focus")
        }
        func reset() { values.removeAll() }
    }

    private func fixture(isPrivate: Bool = false) -> TabStore {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let library = Library.shared
        let old = (library.section, library.query, library.littleArcOnly, library.completedOnly)
        let store = TabStore(isPrivate: isPrivate, profileID: UUID(), session: [])
        let restorationStore = isPrivate ? TabStore(profileID: UUID(), session: []) : store
        store.palette = nil
        Library.open(.archived, in: store)
        library.query = ""
        library.littleArcOnly = false
        library.completedOnly = false
        store.findOpen = false
        addTeardownBlock { @MainActor in
            Library.open(old.0, in: restorationStore)
            library.query = old.1
            library.littleArcOnly = old.2
            library.completedOnly = old.3
            let stores = isPrivate ? [store, restorationStore] : [store]
            for target in stores {
                target.libraryOpen = false
                target.dropStashes()
                let tabs = target.tabs
                TabStore.all.removeAll { $0 === target }
                SharedTabs.release(tabs)
                if !target.isPrivate { Store.forget(target.profileID) }
            }
        }
        return store
    }

    func testSectionChangePublishesOnlyChangedStateAndAlwaysRequestsFocus() {
        let store = fixture()
        let publications = Publications(store: store)
        let before = Library.shared.focusToken
        Library.open(.downloads, in: store)
        XCTAssertEqual(publications.values, ["section": 1, "focus": 1],
                       "Changing a section must not republish already-open window chrome or empty search")
        XCTAssertEqual(Library.shared.section, .downloads)
        XCTAssertEqual(Library.shared.focusToken, before &+ 1)
        publications.reset()
        Library.open(.downloads, in: store)
        XCTAssertEqual(publications.values, ["focus": 1],
                       "Repeated activation still requests search focus without rebuilding unchanged state")
    }

    func testFreshOpeningResetsRealFiltersQueryAndFindExactlyOnce() {
        let store = fixture()
        store.libraryOpen = false
        store.findOpen = true
        Library.shared.query = "needle"
        Library.shared.littleArcOnly = true
        Library.shared.completedOnly = true
        let publications = Publications(store: store)
        Library.open(.downloads, in: store)
        XCTAssertEqual(publications.values,
                       ["section": 1, "query": 1, "little": 1, "completed": 1, "find": 1, "open": 1, "focus": 1])
        XCTAssertTrue(store.libraryOpen)
        XCTAssertFalse(store.findOpen)
        XCTAssertEqual(Library.shared.query, "")
        XCTAssertFalse(Library.shared.littleArcOnly)
        XCTAssertFalse(Library.shared.completedOnly)
        publications.reset()
        Library.close(store)
        XCTAssertEqual(publications.values, ["open": 1])
        publications.reset()
        Library.close(store)
        XCTAssertEqual(publications.values, [:], "An already-closed Library must not republish false")
    }

    func testSectionChangeClearsQueryButKeepsVisitFiltersAndPrivateFallback() {
        let store = fixture(isPrivate: true)
        Library.shared.query = "needle"
        Library.shared.littleArcOnly = true
        Library.shared.completedOnly = true
        let publications = Publications(store: store)
        Library.open(.downloads, in: store)
        XCTAssertEqual(publications.values, ["section": 1, "query": 1, "focus": 1])
        XCTAssertTrue(Library.shared.littleArcOnly)
        XCTAssertTrue(Library.shared.completedOnly)
        publications.reset()
        Library.open(.spaces, in: store)
        XCTAssertEqual(Library.shared.section, .archived, "Private-unavailable sections retain the real fallback")
        XCTAssertEqual(publications.values, ["section": 1, "focus": 1])
        publications.reset()
        Library.focusSearch()
        Library.focusSearch()
        XCTAssertEqual(publications.values, ["focus": 2], "Repeated keyboard focus requests must never be deduplicated")
    }
}
