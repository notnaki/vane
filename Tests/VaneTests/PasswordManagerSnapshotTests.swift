import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Settings → Passwords at the default Settings window size, light and dark, with a names-only
/// fixture list (no Keychain) and a stubbed lock (no Touch ID). Set
/// `VANE_PASSWORD_SNAPSHOTS=<dir>` to write the PNGs for visual sign-off.
@MainActor final class PasswordManagerSnapshotTests: XCTestCase {
    private let profile = ProfileManager.defaultID
    private let fixture = [
        Passwords.Login(host: "mail.example", account: "ada@example.com"),
        Passwords.Login(host: "mail.example", account: "work@example.com"),
        Passwords.Login(host: "bank.example", account: "ada"),
        Passwords.Login(host: "github.com", account: "ada-lovelace"),
        Passwords.Login(host: "news.example", account: ""),
        Passwords.Login(host: "shop.example", account: "ada+shop@example.com"),
    ]

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        UserDefaults.vane.removeObject(forKey: PasswordPaneLock.requiredKey)
    }

    private func unlockedLock() -> PasswordPaneLock {
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, done in done(true) })
        lock.unlock(profile)
        return lock
    }

    private func pane(lock: PasswordPaneLock, deletion: PasswordPendingDeletion = .init(delete: { _, _ in }),
                      secrets: PasswordManagerSecrets? = nil, openHost: String? = nil) -> some View {
        let logins = fixture
        // The window's content area and SettingsView's chrome above a profile pane.
        return VStack(alignment: .leading, spacing: 0) {
            Label("Back to Profiles", systemImage: "chevron.left").foregroundStyle(Color.accentColor)
                .padding(.top, 20)
            Text("Personal").font(Look.caption).foregroundStyle(.secondary).padding(.top, 8)
            PasswordsPane(settingsProfileID: profile, lock: lock, deletion: deletion,
                          fetch: { _ in logins }, secrets: secrets, openHost: openHost)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 64).padding(.bottom, 24)
        .frame(width: 760, height: 560, alignment: .top)
        .font(Look.text)
        .toggleStyle(.switch)
    }

    @discardableResult
    private func render<V: View>(_ view: V, name: String? = nil, width: CGFloat? = nil, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width ?? 760, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        hosting.appearance = appearance
        window.contentView = hosting
        defer { window.close() }
        window.orderFront(nil)
        // Fetches, the lock and the toast all settle on the main actor.
        for _ in 0..<4 {
            hosting.frame.size = CGSize(width: width ?? 760, height: max(1, hosting.fittingSize.height))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        }
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let folder = ProcessInfo.processInfo.environment["VANE_PASSWORD_SNAPSHOTS"], let name {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        return bitmap
    }

    private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        Set(stride(from: 0, to: bitmap.pixelsHigh, by: 6).flatMap { y in
            stride(from: 0, to: bitmap.pixelsWide, by: 6).compactMap { bitmap.colorAt(x: $0, y: y)?.description }
        }).count
    }

    func testUnlockedListLockedStateDetailToastAndAddSheet() throws {
        for dark in [false, true] {
            let list = try render(pane(lock: unlockedLock()), name: "list", dark: dark)
            XCTAssertGreaterThan(distinctColors(list), 4)

            let denied = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, _ in })
            try render(pane(lock: denied), name: "locked", dark: dark)

            let secrets = PasswordManagerSecrets()
            secrets.revealed[fixture[0].id] = "Il1O0-pass!42"
            try render(pane(lock: unlockedLock(), secrets: secrets, openHost: "mail.example"),
                       name: "detail", dark: dark)

            let deletion = PasswordPendingDeletion(grace: .seconds(60), delete: { _, _ in })
            deletion.schedule(fixture[2], profileID: profile)
            defer { deletion.undo() }
            try render(pane(lock: unlockedLock(), deletion: deletion), name: "undo-toast", dark: dark)

            try render(PasswordAddForm(site: .constant("accounts.example.com"), account: .constant("ada"),
                                       password: .constant("fixture-password"), problem: nil,
                                       cancel: {}, save: {}).fixedSize(),
                       name: "add-sheet", width: 460, dark: dark)
        }
    }

    /// The locked pane draws no login names at all, and asks once on appearance.
    func testLockedPaneHidesTheListAndPromptsOnAppear() throws {
        var asked = 0
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, _ in asked += 1 })
        let locked = try render(pane(lock: lock), dark: false)
        XCTAssertEqual(asked, 1, "Opening the pane must ask for authentication")
        let unlocked = try render(pane(lock: unlockedLock()), dark: false)
        XCTAssertNotEqual(locked.representation(using: .png, properties: [:]),
                          unlocked.representation(using: .png, properties: [:]))
    }
}
