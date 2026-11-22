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
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, done in done(true); return nil })
        lock.unlock(profile)
        return lock
    }

    private func pane(lock: PasswordPaneLock, deletion: PasswordPendingDeletion = .init(delete: { _, _ in }),
                      secrets: PasswordManagerSecrets? = nil, openHost: String? = nil,
                      logins: [Passwords.Login]? = nil) -> some View {
        let logins = logins ?? fixture
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

            let denied = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, _ in nil })
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

    /// The locked pane draws no login names at all, and asks once on appearance: what it
    /// draws must not depend on which logins are saved, while the unlocked list does.
    func testLockedPaneHidesTheListAndPromptsOnAppear() throws {
        var asked = 0
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, _ in asked += 1; return nil })
        let png = { (bitmap: NSBitmapImageRep) in bitmap.representation(using: .png, properties: [:]) }
        let locked = try render(pane(lock: lock), dark: false)
        XCTAssertEqual(asked, 1, "Opening the pane must ask for authentication")
        let lockedEmpty = try render(pane(lock: lock, logins: []), dark: false)
        XCTAssertEqual(png(locked), png(lockedEmpty), "A locked pane must not draw anything of the saved logins")
        let open = try render(pane(lock: unlockedLock()), dark: false)
        let openEmpty = try render(pane(lock: unlockedLock(), logins: []), dark: false)
        XCTAssertNotEqual(png(open), png(openEmpty), "The unlocked list must show, or the check above proves nothing")
        XCTAssertNotEqual(png(locked), png(open))
    }

    // MARK: Pane wiring

    private final class Selection: ObservableObject {
        @Published var profile: UUID?
        init(_ profile: UUID?) { self.profile = profile }
    }

    private struct Switching: View {
        @ObservedObject var selection: Selection
        let lock: PasswordPaneLock
        let deletion: PasswordPendingDeletion
        let logins: [Passwords.Login]
        var body: some View {
            PasswordsPane(settingsProfileID: selection.profile, lock: lock, deletion: deletion,
                          fetch: { [logins] _ in logins })
                .frame(width: 632, height: 480)
        }
    }

    /// An attached, offscreen window that stays up while the test changes state.
    private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 760, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        settle(hosting)
        return (window, hosting)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func deletion(counting deletes: @escaping () -> Void) -> PasswordPendingDeletion {
        PasswordPendingDeletion(grace: .seconds(60)) { _, _ in deletes() }
    }

    /// A pane instance that last showed another profile must not keep that unlock.
    func testOpeningThePaneForAnotherProfileRelocks() throws {
        var asked = 0
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, done in
            asked += 1; done(asked == 1); return nil
        })
        let elsewhere = UUID()
        lock.unlock(elsewhere)
        XCTAssertEqual(lock.unlockedProfile, elsewhere)
        let (window, _) = host(pane(lock: lock))
        defer { window.close() }
        XCTAssertNil(lock.unlockedProfile, "Opening another profile's passwords must relock the first")
        XCTAssertEqual(asked, 2, "…and ask for this profile")
    }

    func testChangingProfileLocksAndRunsThePendingDelete() throws {
        let manager = ProfileManager.shared
        let other = manager.create(name: "Password pane switch fixture")
        defer { _ = manager.delete(other.id) }
        var deletes = 0
        let deletion = deletion { deletes += 1 }
        let lock = unlockedLock()
        let selection = Selection(profile)
        let (window, hosting) = host(Switching(selection: selection, lock: lock, deletion: deletion, logins: fixture))
        defer { window.close() }
        deletion.schedule(fixture[0], profileID: profile)
        selection.profile = other.id
        settle(hosting)
        XCTAssertNil(lock.unlockedProfile, "Switching profile must lock the list")
        XCTAssertNil(deletion.pending)
        XCTAssertEqual(deletes, 1, "Switching profile must run the delete waiting on its toast")
    }

    func testLockingTheOpenPaneRunsThePendingDeleteAndForgetsSecrets() throws {
        var deletes = 0
        let deletion = deletion { deletes += 1 }
        let lock = unlockedLock()
        let secrets = PasswordManagerSecrets()
        let (window, hosting) = host(pane(lock: lock, deletion: deletion, secrets: secrets, openHost: "mail.example"))
        defer { window.close() }
        secrets.revealed[fixture[0].id] = "fixture-secret"
        deletion.schedule(fixture[2], profileID: profile)
        lock.lock()
        settle(hosting)
        XCTAssertTrue(secrets.revealed.isEmpty, "A locked pane must not keep a revealed password")
        XCTAssertEqual(deletes, 1, "Locking must run the delete waiting on its toast")
    }

    func testPresentingThePaneAgainAsksAgain() throws {
        var asked = 0
        let lock = PasswordPaneLock(distributed: NotificationCenter(), authenticate: { _, done in
            asked += 1; done(false); return nil
        })
        let (window, hosting) = host(pane(lock: lock))
        defer { window.close() }
        XCTAssertEqual(asked, 1)
        NotificationCenter.default.post(name: SettingsWindow.presentationRequest, object: "general")
        settle(hosting)
        XCTAssertEqual(asked, 1, "Another pane's presentation is not a reason to ask")
        NotificationCenter.default.post(name: SettingsWindow.presentationRequest, object: "passwords")
        settle(hosting)
        XCTAssertEqual(asked, 2, "Reopening Passwords on a retained view must ask again")
    }

    /// Delete, leave the pane before the toast expires, save the same login again: the
    /// next list holds it, and it must be listed rather than stay hidden until relaunch.
    func testALoginSavedAgainAfterItsDeleteIsListedOnTheNextVisit() async throws {
        var deletes = 0
        let deletion = deletion { deletes += 1 }
        deletion.schedule(fixture[0], profileID: profile)
        deletion.commit()
        try await compatibilityWait { deletes == 1 && !deletion.gone.isEmpty }
        XCTAssertTrue(deletion.hides(fixture[0], profileID: profile))
        let (window, _) = host(pane(lock: unlockedLock(), deletion: deletion))
        defer { window.close() }
        try await compatibilityWait { !deletion.hides(self.fixture[0], profileID: self.profile) }
    }

    func testUndoShortcutLeavesTextEditingAlone() throws {
        SettingsWindow.show(tab: "general")
        let window = try XCTUnwrap(NSApp.windows.first(where: { SettingsWindow.holds($0) }))
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        defer { window.close() }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, in target: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: target.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6)!
        }
        window.makeFirstResponder(nil)
        XCTAssertTrue(PasswordUndoToast.takesUndo(key("z", .command, in: window)))
        XCTAssertFalse(PasswordUndoToast.takesUndo(key("z", [.command, .shift], in: window)), "⇧⌘Z is redo")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(field)
        defer { field.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(PasswordUndoToast.takesUndo(key("z", .command, in: window)),
                       "⌘Z while editing text is text undo, not the toast's")
        let browser = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 100),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        defer { browser.close() }
        XCTAssertFalse(PasswordUndoToast.takesUndo(key("z", .command, in: browser)), "Only in Settings")
    }
}
