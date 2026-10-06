import AppKit
import Security
import SwiftUI
import XCTest
@testable import vane

@MainActor final class PasswordChooserLayoutTests: XCTestCase {
    func testChooserFitsAPaneNarrowerThanItsPreferredWidth() {
        let viewport = CGSize(width: 180, height: 400)
        let anchor = CGRect(x: 160, y: 50, width: 40, height: 0)
        let width = PasswordChooser.width(of: anchor, in: viewport)
        let origin = PasswordChooser.place(anchor: anchor, in: viewport, height: 160)
        XCTAssertLessThanOrEqual(width, viewport.width)
        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(
            CGRect(origin: origin ?? .zero, size: CGSize(width: width, height: 160))))
    }

    func testChooserRefusesAPaneTooShortToDisplayItsContent() {
        XCTAssertNil(PasswordChooser.place(anchor: CGRect(x: 10, y: 20, width: 200, height: 0),
            in: CGSize(width: 300, height: 100), height: 160))
    }

    func testChooserRefusesInvalidPageCoordinates() {
        let viewport = CGSize(width: 800, height: 600)
        for anchor in [CGRect(x: CGFloat.nan, y: 20, width: 200, height: 0),
                       CGRect(x: 20, y: 20, width: CGFloat.infinity, height: 0)] {
            XCTAssertNil(PasswordChooser.place(anchor: anchor, in: viewport, height: 160))
        }
    }

    func testLongAccountListsFitTheViewportAndKeepAWholeRowVisible() throws {
        let viewport = CGSize(width: 240, height: 220)
        let height = PasswordChooser.height(rows: 30, in: viewport)
        let origin = try XCTUnwrap(PasswordChooser.place(
            anchor: CGRect(x: 200, y: 200, width: 200, height: 0), in: viewport, height: height))
        let frame = CGRect(origin: origin, size: CGSize(width: 240, height: height))
        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
        XCTAssertGreaterThanOrEqual(height - PasswordChooser.chromeHeight, Look.passwordChooserRow)
    }
}

@MainActor final class PasswordManagerSearchTests: XCTestCase {
    func testSearchCombinesSiteAndUsernameAndIgnoresExtraWhitespace() {
        let logins = [Passwords.Login(host: "mail.example", account: "ada@example.com"),
                      Passwords.Login(host: "mail.example", account: "bob@example.com"),
                      Passwords.Login(host: "bank.example", account: "bob")]
        XCTAssertEqual(PasswordsPane.groups(logins, query: " mail\n BOB ").flatMap(\.logins),
                       [logins[1]])
        XCTAssertTrue(PasswordsPane.groups(logins, query: "bank ada").isEmpty)
        XCTAssertEqual(PasswordsPane.groups(logins, query: "\n\t ").flatMap(\.logins).count, 3)
    }

    func testNeverSavedSearchUsesTheSameWhitespaceRules() {
        XCTAssertEqual(PasswordsPane.matching(["mail.example", "bank.example"], query: " mail\nexample "),
                       ["mail.example"])
    }
}

@MainActor final class PasswordPopupPresentationTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
    }

    private func render<V: View>(_ view: V, width: CGFloat, name: String? = nil) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        window.orderFront(nil)
        hosting.frame.size = CGSize(width: width, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.frame.size = CGSize(width: width, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(hosting.bounds.width), pixelsHigh: Int(ceil(hosting.bounds.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["VANE_PASSWORD_SNAPSHOTS"], let name {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func offer(_ password: String, update: Bool = false, host: String = "accounts.example.com",
                       account: String = "ada@example.com") -> PasswordOfferCard {
        PasswordOfferCard(offer: PendingSave(host: host, account: account, password: password, update: update),
                          profileID: ProfileManager.defaultID, dismiss: {}, save: {}, never: {})
    }

    func testSaveOfferMasksBothThePasswordAndItsLength() throws {
        let short = try render(offer("x"), width: 340, name: "save-password")
        let long = try render(offer(String(repeating: "secret", count: 30)), width: 340, name: "concealed-long")
        XCTAssertEqual(short.representation(using: .png, properties: [:]),
                       long.representation(using: .png, properties: [:]),
                       "A concealed credential must render identically regardless of its secret")
    }

    func testUpdateOfferFitsLongSiteAndAccountNamesInANarrowWindow() throws {
        let bitmap = try render(offer("fixture", update: true,
            host: "a-very-long-subdomain.accounts.example.com",
            account: "a-long-email-address-with-a-long-name@example.com"), width: 260, name: "update-password")
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, 260)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, 320)
    }

    func testChooserRendersWithinItsCalculatedHitArea() throws {
        for count in [1, 2, 12] {
            let choice = PasswordChoice(host: "accounts.example.com",
                accounts: (0..<count).map { "account-\($0)@example.com" }, anchor: .zero)
            let height = PasswordChooser.height(rows: count)
            let card = PasswordChooserCard(choice: choice, profileID: ProfileManager.defaultID,
                width: 280, height: height, fill: { _ in }, manage: {})
            let bitmap = try render(card, width: 280, name: "autofill-\(count)")
            XCTAssertEqual(bitmap.pixelsWide, 280)
            XCTAssertEqual(bitmap.pixelsHigh, Int(height), "Native click dismissal must use the drawn card's bounds")
        }
    }

    func testFailedKeychainSaveKeepsTheOfferOpenAndReportsTheProblem() throws {
        let profile = UUID()
        let host = "password-popup-fixture-\(UUID().uuidString.lowercased()).invalid"
        let account = "fixture"
        let foreign: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrSecurityDomain as String: try XCTUnwrap(Passwords.namespace(profileID: profile,
                                                                              dataDir: Store.overrideDirectory)),
            kSecAttrCreator as String: NSNumber(value: 0x5465_7374),
        ]
        var item = foreign
        item[kSecValueData as String] = Data("foreign-fixture".utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCTSkip("Fixture Keychain unavailable: \(status)") }
        defer { SecItemDelete(foreign as CFDictionary) }
        let tab = Tab(profileID: profile)
        let pending = PendingSave(host: host, account: account, password: "new-fixture")
        tab.pendingSave = pending
        tab.confirmSave()
        XCTAssertEqual(tab.pendingSave, pending)
        XCTAssertNotNil(tab.passwordSaveProblem)
        XCTAssertNil(Passwords.password(host: host, account: account, profileID: profile))
    }

    func testManagerRendersSavedSitesWithinTheSettingsPane() throws {
        let profile = ProfileManager.defaultID
        let logins = [Passwords.Login(host: "mail.example", account: "ada@example.com"),
                      Passwords.Login(host: "mail.example", account: "work@example.com"),
                      Passwords.Login(host: "bank.example", account: "ada")]
        defer { for login in logins { Passwords.delete(host: login.host, account: login.account, profileID: profile) } }
        for login in logins {
            guard Passwords.save(host: login.host, account: login.account, password: "fixture", profileID: profile)
            else { throw XCTSkip("Fixture Keychain unavailable") }
        }
        let bitmap = try render(PasswordsPane(settingsProfileID: profile).padding(24), width: 632, name: "manager")
        XCTAssertEqual(bitmap.pixelsWide, 632)
        XCTAssertLessThan(bitmap.pixelsHigh, 560)
    }
}
