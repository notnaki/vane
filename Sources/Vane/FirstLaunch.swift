import AppKit
import SwiftUI

/// Capture this before startup creates profiles, Spaces, or the history database. A
/// pending welcome survives an interrupted launch; an upgrade never becomes a new install.
@MainActor final class FirstLaunchState {
    private let defaults: UserDefaults
    private static let key = "firstLaunchWelcome"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func prepare(directory: URL, legacy: URL? = nil) -> Bool {
        if let saved = defaults.string(forKey: Self.key) { return saved == "pending" }
        guard let fresh = Self.isFresh(directory),
              let legacyFresh = legacy.map(Self.isFresh) ?? .some(true) else { return false }
        let shouldShow = fresh && legacyFresh
        defaults.set(shouldShow ? "pending" : "completed", forKey: Self.key)
        return shouldShow
    }

    func complete() { defaults.set("completed", forKey: Self.key) }

    private static func isFresh(_ directory: URL) -> Bool? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return !names.contains { name in
                name == "profiles.json" || name.hasSuffix(".db")
                    || name.hasSuffix("session.json") || name.hasSuffix("spaces.json")
            }
        } catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? true : nil
        }
    }
}

/// Keep incoming links in the real browser while setup fills its window.
@MainActor enum FirstLaunch {
    private static let state = FirstLaunchState(defaults: .vane)
    private(set) static var needed = false
    private static var presentation: FirstLaunchPresentation?
    static var isPresenting: Bool { presentation != nil }

    static func prepare() {
        needed = state.prepare(directory: Store.directory,
                               legacy: Store.overrideDirectory == nil ? LegacyData.legacy : nil)
    }

    @discardableResult static func presentIfNeeded() -> Bool {
        guard needed, !isPresenting else { return false }
        let store = Windows.main ?? Windows.open()
        guard let host = store.window else { return false }
        let welcome = FirstLaunchPresentation(host: host, content: AnyView(
            FirstLaunchView(store: store) { finish(store: store, host: host) }
        ), onHostClose: { finish(store: store, host: host, showBrowser: false) })
        presentation = welcome
        welcome.show()
        return true
    }

    private static func finish(store: TabStore, host: NSWindow, showBrowser: Bool = true) {
        guard let welcome = presentation else { return }
        state.complete()
        needed = false
        welcome.close()
        presentation = nil
        guard showBrowser else { return }
        host.makeKeyAndOrderFront(nil)
        // Leave the dismissal event behind before offering another dialog.
        Task { @MainActor in
            URLHandling.promptIfNotDefaultOnce()
            if store.current == nil, store.palette == nil { store.openPalette(.newTab) }
        }
    }
}

/// Bundled captures of the real browser, and the exact V from its shipped icon SVG.
@MainActor enum WelcomeArtwork {
    static let logo = load("VaneLogo", extension: "pdf")
    static let search = load("Search", extension: "png")
    static let spaces = load("Spaces", extension: "png")

    private static func load(_ name: String, extension ext: String) -> NSImage {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: ext, subdirectory: "WelcomeAssets"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: .zero) }
        return image
    }
}
