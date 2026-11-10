import AppKit
import SwiftUI

enum WelcomeStep: Int, CaseIterable {
    case welcome, tabs, theme, search, ai, bringBrowser, ready

    var label: String {
        switch self {
        case .welcome: "Welcome"
        case .tabs: "Your tabs"
        case .theme: "Your Spaces"
        case .search: "Search"
        case .ai: "AI features"
        case .bringBrowser: "Bring your browser"
        case .ready: "Ready"
        }
    }
}

enum WelcomeImportSource: String, CaseIterable, Identifiable {
    case arc = "Arc", chrome = "Chrome", safari = "Safari", firefox = "Firefox", brave = "Brave"
    case zen = "Zen", orion = "Orion", edge = "Edge", chromium = "Chromium", vivaldi = "Vivaldi", opera = "Opera"
    var id: String { rawValue }
    var bundleID: String {
        switch self {
        case .arc: "company.thebrowser.Browser"
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        case .firefox: "org.mozilla.firefox"
        case .brave: "com.brave.Browser"
        case .zen: "app.zen-browser.zen"
        case .orion: "com.kagi.kagimacOS"
        case .edge: "com.microsoft.edgemac"
        case .chromium: "org.chromium.Chromium"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        }
    }
    @MainActor var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    @MainActor static var installedNames: Set<String> {
        Set(allCases.compactMap { source in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID),
                  FileManager.default.fileExists(atPath: url.path),
                  Bundle(url: url)?.bundleIdentifier == source.bundleID else { return nil }
            return source.rawValue
        })
    }
}

/// Own only real setup choices. Preview tabs and Spaces never enter the browser's store.
@MainActor final class FirstLaunchSetup: ObservableObject {
    @Published private(set) var step = WelcomeStep.welcome
    @Published private(set) var color: String
    @Published private(set) var engine = Search.current
    let store: TabStore
    let importer: OnboardingImport
    private let finish: () -> Void
    var showsSetupControls: Bool { step != .welcome }

    init(store: TabStore, importHome: URL = BrowserImport.sourceHome, finish: @escaping () -> Void) {
        self.store = store
        self.finish = finish
        importer = OnboardingImport(store: store, home: importHome)
        color = store.currentSpace?.colorHex ?? "#F2EAE4"
    }

    func advance() {
        guard let next = WelcomeStep(rawValue: step.rawValue + 1) else { finish(); return }
        step = next
    }
    func back() {
        if let previous = WelcomeStep(rawValue: step.rawValue - 1) { step = previous }
    }
    func skip() { finish() }

    func chooseColor(_ hex: String) {
        guard let chosen = Look.themePresetColors[hex], var space = store.currentSpace else { return }
        Spaces.setPalette([chosen], on: &space)
        store.update(space: space)
        color = hex
    }
    func applySpace(_ space: Space) {
        guard space.id == store.currentSpaceID else { return }
        store.update(space: space)
        color = space.colorHex ?? color
    }
    func chooseEngine(_ selected: SearchEngine) {
        Search.current = selected
        engine = selected
    }
}

struct WelcomePalette {
    let dark: Bool
    var ink: Color { dark ? Color(white: 0.94) : Color(red: 0.15, green: 0.17, blue: 0.15) }
    var muted: Color { dark ? Color(red: 0.66, green: 0.69, blue: 0.67) : Color(red: 0.36, green: 0.40, blue: 0.37) }
    var paper: Color { dark ? Color(white: 0.035) : Color(red: 0.96, green: 0.96, blue: 0.94) }
    var surface: Color { dark ? Color(white: 0.09) : Color(red: 0.91, green: 0.93, blue: 0.90) }
    var line: Color { ink.opacity(dark ? 0.15 : 0.18) }
}
