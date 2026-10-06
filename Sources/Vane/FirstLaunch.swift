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

/// One sheet on the initial browser window. AppKit keeps focus inside the welcome and
/// leaves incoming links intact in the browser underneath it.
@MainActor enum FirstLaunch {
    private static let state = FirstLaunchState(defaults: .vane)
    private static var needed = false
    private static var sheet: NSWindow?
    static var isPresenting: Bool { sheet != nil }

    static func prepare() {
        needed = state.prepare(directory: Store.directory,
                               legacy: Store.overrideDirectory == nil ? LegacyData.legacy : nil)
    }

    @discardableResult static func presentIfNeeded() -> Bool {
        guard needed, !isPresenting, let store = Windows.main, let host = store.window else { return false }
        let welcome = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                               styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        welcome.title = "Welcome to Vane"
        welcome.titleVisibility = .hidden
        welcome.titlebarAppearsTransparent = true
        welcome.isReleasedWhenClosed = false
        welcome.contentView = NSHostingView(rootView: FirstLaunchView { finish(store: store, host: host) })
        sheet = welcome
        host.beginSheet(welcome)
        return true
    }

    private static func finish(store: TabStore, host: NSWindow) {
        guard let welcome = sheet else { return }
        state.complete()
        needed = false
        host.endSheet(welcome)
        welcome.orderOut(nil)
        sheet = nil
        host.makeKeyAndOrderFront(nil)
        // Leave the sheet's dismissal event behind before offering another dialog.
        Task { @MainActor in
            URLHandling.promptIfNotDefaultOnce()
            if store.current == nil, store.palette == nil { store.openPalette(.newTab) }
        }
    }
}

private enum WelcomePage: Int, CaseIterable {
    case welcome, search, spaces
    var eyebrow: String {
        switch self {
        case .welcome: "A LITTLE MORE ROOM"
        case .search: "FOLLOW YOUR CURIOSITY"
        case .spaces: "A PLACE FOR EVERYTHING"
        }
    }
    var title: String {
        switch self {
        case .welcome: "Make yourself\nat home."
        case .search: "One little bar.\nAnywhere."
        case .spaces: "Your world,\nin Spaces."
        }
    }
    var detail: String {
        switch self {
        case .welcome: "Welcome to Vane. A quieter place for your tabs, your ideas, and wherever the web takes you."
        case .search: "Search, open a site, or find a tab. It all starts in the same place."
        case .spaces: "Give work, life, and everything in between a space of their own. Keep the pages you love close by."
        }
    }
    var hint: String {
        switch self {
        case .welcome: "Built for your Mac. Made for you."
        case .search: "⌘T for somewhere new · ⌘L for this page"
        case .spaces: "Add a Space from the sidebar."
        }
    }
}

private struct FirstLaunchView: View {
    let finish: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var saver = BatterySaver.shared
    @State private var page = WelcomePage.welcome
    @State private var drawn = false
    @State private var settled = false
    @AccessibilityFocusState private var titleFocused: Bool
    private var reduced: Bool { reduceMotion || saver.isActive }
    private var ink: Color { scheme == .dark ? Color(red: 0.91, green: 0.92, blue: 0.98) : Color(red: 0.16, green: 0.19, blue: 0.31) }
    private var ground: Color { scheme == .dark ? Color(red: 0.10, green: 0.12, blue: 0.19) : Color(red: 0.95, green: 0.95, blue: 0.98) }
    private let accent = Color(red: 0.46, green: 0.48, blue: 0.80)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: WelcomeArtwork.logo).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 21, height: 24).accessibilityHidden(true)
                Text("Vane").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Skip intro", action: finish)
                    .buttonStyle(.plain).foregroundStyle(ink.opacity(0.65))
                    .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 22)
            HStack(alignment: .center, spacing: 30) {
                VStack(alignment: .leading, spacing: 19) {
                    Text(page.eyebrow).font(.system(size: 10, weight: .semibold)).tracking(2)
                        .foregroundStyle(ink.opacity(0.55))
                    Text(page.title).font(.system(size: 44, weight: .medium, design: .rounded))
                        .tracking(-1.7).lineSpacing(-1).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    Text(page.detail).font(.system(size: 15)).lineSpacing(5)
                        .foregroundStyle(ink.opacity(0.70)).fixedSize(horizontal: false, vertical: true)
                    Text(page.hint).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.55)).padding(.top, 7)
                }
                .frame(width: 300, alignment: .leading)
                .id(page)
                .transition(reduced ? .identity : .opacity.combined(with: .offset(y: 7)))
                WelcomePreview(page: page, revealed: drawn || reduced, ink: ink, accent: accent)
                    .frame(width: 390, height: 310)
                    .accessibilityHidden(true)
            }
            .opacity(settled || reduced ? 1 : 0)
            .offset(y: settled || reduced ? 0 : 10)
            Spacer(minLength: 22)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(WelcomePage.allCases, id: \.rawValue) { item in
                        Capsule().fill(item == page ? ink : ink.opacity(0.18))
                            .frame(width: item == page ? 23 : 6, height: 6)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Introduction, step \(page.rawValue + 1) of 3")
                Spacer()
                if page != .welcome {
                    Button("Back") { changePage(to: WelcomePage(rawValue: page.rawValue - 1)!) }
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.65)).padding(.trailing, 14)
                }
                Button(action: advance) {
                    HStack(spacing: 22) {
                        Text(page == .spaces ? "Start browsing" : "Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 20).frame(height: 42)
                }
                .buttonStyle(WelcomeButtonStyle(ink: ink, label: ground, reduced: reduced))
                .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 32)
        .frame(width: 840, height: 560)
        .background {
            ground
            RadialGradient(colors: [accent.opacity(scheme == .dark ? 0.18 : 0.12), .clear],
                           center: .trailing, startRadius: 20, endRadius: 540)
        }
        .ignoresSafeArea()
        .task(id: reduced) {
            if reduced { drawn = true; settled = true; return }
            withAnimation(.easeOut(duration: 0.28)) { settled = true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            withAnimation(.spring(duration: 0.65, bounce: 0.08)) { drawn = true }
        }
    }

    private func advance() {
        if page == .spaces { finish() }
        else { changePage(to: WelcomePage(rawValue: page.rawValue + 1)!) }
    }
    private func changePage(to next: WelcomePage) {
        withAnimation(reduced ? nil : Look.appear) { page = next }
        titleFocused = true
    }
}

private struct WelcomeButtonStyle: ButtonStyle {
    let ink: Color
    let label: Color
    let reduced: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(label)
            .background(ink.opacity(configuration.isPressed ? 0.78 : 1), in: .rect(cornerRadius: 12))
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? nil : Look.quick, value: configuration.isPressed)
    }
}

/// Bundled captures of the real browser, and the exact V from its shipped icon SVG.
@MainActor enum WelcomeArtwork {
    static let logo = load("VaneLogo", extension: "pdf")
    static let search = load("Search", extension: "png")
    static let spaces = load("Spaces", extension: "png")

    private static func load(_ name: String, extension ext: String) -> NSImage {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "WelcomeAssets"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: .zero) }
        return image
    }
}

private struct WelcomePreview: View {
    let page: WelcomePage
    let revealed: Bool
    let ink: Color
    let accent: Color

    var body: some View {
        ZStack {
            if page == .welcome {
                Ellipse().strokeBorder(accent.opacity(0.12), lineWidth: 1)
                    .frame(width: 290, height: 290)
                Ellipse().strokeBorder(accent.opacity(0.07), lineWidth: 1)
                    .frame(width: 350, height: 350)
                Image(nsImage: WelcomeArtwork.logo)
                    .renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(LinearGradient(colors: [ink.opacity(0.9), accent, ink.opacity(0.65)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 146, height: 167)
                    .shadow(color: accent.opacity(0.25), radius: 24, y: 12)
                    .scaleEffect(revealed ? 1 : 0.9)
                    .blur(radius: revealed ? 0 : 8)
                    .opacity(revealed ? 1 : 0)
                    .rotationEffect(.degrees(revealed ? 0 : -6))
            } else {
                VStack(spacing: 16) {
                    screenshot
                        .rotationEffect(.degrees(page == .search ? -2 : 2))
                        .shadow(color: ink.opacity(0.14), radius: 22, y: 14)
                    Text(page == .search ? "Everything starts here." : "A little room for every part of you.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.55))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    private var screenshot: some View {
        Image(nsImage: page == .search ? WelcomeArtwork.search : WelcomeArtwork.spaces)
            .resizable().scaledToFill()
            // Enlarge the captured controls inside the viewport so their labels stay legible.
            .scaleEffect(page == .search ? 1.6 : 2, anchor: page == .search ? .center : .topLeading)
            .frame(width: 354, height: 238)
            .clipped()
            .clipShape(.rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ink.opacity(0.12)))
    }
}
