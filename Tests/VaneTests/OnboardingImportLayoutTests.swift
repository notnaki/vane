import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class OnboardingImportLayoutTests: XCTestCase {
    func testReviewCardKeepsItsWidthButFitsHeightToTheSelectedContent() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Unshown hosting views only: no window or activation.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("import-layout-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let flow = OnboardingImport(store: store, home: home)
        await flow.scan()
        let url = URL(string: "https://layout.example.test/")!
        var sidebar = ArcSidebar()
        sidebar.spaces = (0..<3).map {
            ArcSpace(id: String($0), title: "Space \($0)", profileDirectory: "Default", themeHex: nil, pinned: [], today: [])
        }
        let scan = ArcImport.Scan(root: home, sidebar: sidebar, profiles: [])
        let arc = OnboardingImport.Candidate(id: "arc", browser: "Arc", profile: "All profiles",
            spaces: 3, tabs: 55, bookmarks: 0, history: 85668, passwords: 252, cookies: 6863, payload: .arc(scan))
        let orion = OnboardingImport.Candidate(id: "orion", browser: "Orion", profile: "Default",
            spaces: 0, tabs: 0, bookmarks: 2, history: 6, passwords: 0, cookies: 0,
            payload: .browser(.init(visits: [], bookmarks: [
                .init(url: url, title: "First bookmark", folder: nil),
                .init(url: url, title: "Second bookmark", folder: nil)])))
        func size(_ candidate: OnboardingImport.Candidate) -> CGSize {
            let host = NSHostingView(rootView: OnboardingImportReview(candidate: candidate, flow: flow,
                palette: WelcomePalette(dark: true)).transaction { $0.disablesAnimations = true })
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let arcSize = size(arc)
        let orionSize = size(orion)
        XCTAssertEqual(arcSize.width, 550, accuracy: 0.5, "Long native segment labels must not widen the card")
        XCTAssertEqual(orionSize.width, arcSize.width, accuracy: 0.5)
        XCTAssertLessThan(orionSize.height, arcSize.height, "Fewer choices and found items should shrink the card vertically")
        let credentials = OnboardingImport.Candidate(id: "credentials", browser: "Arc", profile: "Default",
            spaces: 0, tabs: 0, bookmarks: 0, history: 0, passwords: 252, cookies: 6863, payload: .arc(scan))
        let credentialSize = size(credentials)
        XCTAssertEqual(credentialSize.width, arcSize.width, accuracy: 0.5)
        XCTAssertLessThan(credentialSize.height, arcSize.height, "Credential descriptions should not reserve an empty list area")
        flow.setIncluded(false, section: .workspace, in: arc)
        let excludedSize = size(arc)
        XCTAssertEqual(excludedSize.width, arcSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(excludedSize.height, arcSize.height, "An exclusion message should take its natural height instead of reserving a blank line")
    }
}
