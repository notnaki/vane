import AppKit
import SwiftUI

private enum WelcomeStep: Int, CaseIterable {
    case welcome, theme, search, ready

    var label: String {
        switch self {
        case .welcome: "Welcome"
        case .theme: "Your space"
        case .search: "Search"
        case .ready: "All yours"
        }
    }
}

/// A short setup that fills the browser window. Choices use the browser's settings.
struct FirstLaunchView: View {
    let store: TabStore
    let finish: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var saver = BatterySaver.shared
    @State private var step = WelcomeStep.welcome
    @State private var selectedColor: String?
    @State private var engine = Search.current
    @AccessibilityFocusState private var titleFocused: Bool

    private var reduced: Bool { reduceMotion || saver.isActive }
    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? Color(red: 0.94, green: 0.92, blue: 0.86) : Color(red: 0.16, green: 0.18, blue: 0.16) }
    private var paper: Color { dark ? Color(red: 0.12, green: 0.14, blue: 0.13) : Color(red: 0.96, green: 0.95, blue: 0.91) }
    private var tint: Color { Color(nsColor: (Look.themePresetColors[color] ?? ThemeColor(hex: color) ?? ThemeColor(red: 0.94, green: 0.92, blue: 0.90)).nsColor) }
    private var color: String { selectedColor ?? store.currentSpace?.colorHex ?? "#F2EAE4" }
    private let colors = [("#F2EAE4", "Linen"), ("#6CBAD9", "Tide"), ("#A6729D", "Iris"), ("#7AA982", "Sage"), ("#FF8558", "Ember")]

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1000 || geometry.size.height < 700
            let inset: CGFloat = compact ? 30 : 54
            VStack(spacing: 0) {
                header
                ScrollView {
                    Group {
                        switch step {
                        case .welcome: welcome(compact: compact)
                        case .theme: setup(compact: compact, title: "A space that\nfeels like you.", detail: "Start with a color. Give every part of your day its own Space whenever you’re ready.") {
                            themeChoices
                        } preview: {
                            WelcomeSpacePreview(tint: tint, dark: dark, ink: ink, paper: paper)
                        }
                        case .search: setup(compact: compact, title: "Follow your\ncuriosity.", detail: "Pick where your searches begin. You can change this anytime in Settings.") {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                Text("One bar for searches, sites, and tabs.")
                            }.font(.system(size: 13)).foregroundStyle(ink.opacity(0.7))
                        } preview: {
                            searchChoices
                        }
                        case .ready: ready(compact: compact)
                        }
                    }
                    .id(step)
                    .transition(reduced ? .identity : .opacity.combined(with: .offset(y: 12)))
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - (compact ? 170 : 220)))
                }
                .scrollIndicators(.hidden)
                footer(compact: compact)
            }
            .padding(.horizontal, inset)
            .padding(.top, compact ? 26 : 42)
            .padding(.bottom, compact ? 26 : 42)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(ink)
            .background {
                paper
                if step == .theme {
                    tint.opacity(dark ? 0.10 : 0.12)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .vaneMotionPolicy()
    }

    private var header: some View {
        HStack(spacing: 10) {
            logo(size: 22)
            Text("Vane").font(.system(size: 19, weight: .medium))
            Spacer()
            Button("Skip setup", action: finish)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(0.72))
                .padding(8)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func welcome(compact: Bool) -> some View {
        VStack(spacing: compact ? 22 : 30) {
            logo(size: compact ? 60 : 82).padding(.bottom, 8)
            heading("A little more room\nfor the internet.", size: compact ? 52 : 76)
                .multilineTextAlignment(.center)
            Text("Your tabs, your ideas, your corner of the web.\nLet’s make it feel like home.")
                .font(.system(size: compact ? 16 : 18)).lineSpacing(6)
                .multilineTextAlignment(.center).foregroundStyle(ink.opacity(0.72))
        }
        .padding(.vertical, 30)
    }

    private func setup<Choices: View, Preview: View>(compact: Bool, title: String, detail: String,
                                                    @ViewBuilder choices: () -> Choices,
                                                    @ViewBuilder preview: () -> Preview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: compact ? 44 : 90) {
                setupCopy(title: title, detail: detail, compact: compact, choices: choices)
                    .frame(width: compact ? 330 : 390, alignment: .leading)
                preview().frame(width: compact ? 360 : 480)
            }
            VStack(alignment: .leading, spacing: 32) {
                setupCopy(title: title, detail: detail, compact: true, choices: choices)
                preview().frame(maxWidth: 480)
            }.frame(maxWidth: 480)
        }
        .padding(.vertical, 30)
    }

    private func setupCopy<Choices: View>(title: String, detail: String, compact: Bool,
                                          @ViewBuilder choices: () -> Choices) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            heading(title, size: compact ? 48 : 62)
            Text(detail).font(.system(size: 17)).lineSpacing(6)
                .foregroundStyle(ink.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            choices().padding(.top, 12)
        }
    }

    private var themeChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ForEach(colors, id: \.0) { hex, name in
                    Button {
                        withAnimation(reduced ? nil : Look.appear) { selectedColor = hex }
                        if var space = store.currentSpace {
                            Spaces.setPalette([Look.themePresetColors[hex]!], on: &space)
                            Motion.animate(Look.quick) { store.update(space: space) }
                        }
                    } label: {
                        Circle().fill(Color(nsColor: Look.themePresetColors[hex]!.nsColor))
                            .frame(width: 38, height: 38)
                            .overlay { if color == hex { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.black.opacity(0.8)) } }
                            .padding(5)
                            .overlay(Circle().strokeBorder(ink.opacity(color == hex ? 0.75 : 0), lineWidth: 1))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(color == hex ? .isSelected : [])
                }
            }
            Text(colors.first { $0.0 == color }?.1 ?? "Your current color")
                .font(.system(size: 13)).foregroundStyle(ink.opacity(0.72))
        }
    }

    private var searchChoices: some View {
        VStack(spacing: 0) {
            ForEach(Search.builtIn) { item in
                Button {
                    withAnimation(reduced ? nil : Look.quick) { engine = item }
                    Search.current = item
                } label: {
                    HStack(spacing: 18) {
                        Text(item.name).font(.system(size: 19, weight: .medium))
                        Spacer()
                        ZStack {
                            Circle().strokeBorder(ink.opacity(0.35), lineWidth: 1).frame(width: 23, height: 23)
                            if item.id == engine.id {
                                Circle().fill(ink).frame(width: 23, height: 23)
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(paper)
                            }
                        }
                    }
                    .padding(.horizontal, 22).frame(height: 60)
                    .background(ink.opacity(item.id == engine.id ? 0.07 : 0), in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.id == engine.id ? .isSelected : [])
            }
        }
    }

    private func ready(compact: Bool) -> some View {
        VStack(spacing: compact ? 24 : 32) {
            heading("The internet is\nyours from here.", size: compact ? 52 : 72)
                .multilineTextAlignment(.center)
            Text("Open a new tab. See where it takes you.")
                .font(.system(size: 18)).foregroundStyle(ink.opacity(0.72))
            HStack(spacing: 10) {
                key("⌘")
                key("T")
            }.padding(.top, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Command T opens a new tab")
            Text("Your tabs live in the sidebar. Spaces keep them in their place.")
                .font(.system(size: 14)).foregroundStyle(ink.opacity(0.72))
                .multilineTextAlignment(.center)
        }.padding(.vertical, 30)
    }

    private func key(_ value: String) -> some View {
        Text(value).font(.system(size: 28, weight: .regular))
            .frame(width: 64, height: 64)
            .background(ink.opacity(0.06), in: .rect(cornerRadius: 12))
    }

    private func footer(compact: Bool) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: compact ? 12 : 24) {
                ForEach(WelcomeStep.allCases, id: \.rawValue) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(ink.opacity(item.rawValue <= step.rawValue ? 0.85 : 0.15))
                            .frame(width: compact ? 32 : 56, height: 2)
                        if !compact { Text(item.label).font(.system(size: 11)).foregroundStyle(ink.opacity(item == step ? 1 : 0.65)) }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup, step \(step.rawValue + 1) of \(WelcomeStep.allCases.count): \(step.label)")
            Spacer(minLength: 20)
            if step != .welcome {
                Button("Back") { change(to: WelcomeStep(rawValue: step.rawValue - 1)!) }
                    .buttonStyle(.plain).font(.system(size: 14))
                    .foregroundStyle(ink.opacity(0.72)).padding(14)
            }
            Button {
                if step == .ready { finish() }
                else { change(to: WelcomeStep(rawValue: step.rawValue + 1)!) }
            } label: {
                HStack(spacing: 28) {
                    Text(step == .welcome ? "Make yourself at home" : step == .ready ? "Start browsing" : "Continue")
                    Image(systemName: "arrow.right")
                }.font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 24).frame(height: 50)
            }
            .buttonStyle(WelcomeButtonStyle(ink: ink, paper: paper, reduced: reduced))
            .keyboardShortcut(.defaultAction)
        }
    }

    private func heading(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .regular, design: .serif))
            .tracking(-size * 0.025).lineSpacing(-2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
    }

    private func logo(size: CGFloat) -> some View {
        Image(nsImage: WelcomeArtwork.logo).renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size * 1.14).accessibilityHidden(true)
    }

    private func change(to next: WelcomeStep) {
        withAnimation(reduced ? nil : .easeInOut(duration: 0.24)) { step = next }
        titleFocused = true
    }
}

private struct WelcomeButtonStyle: ButtonStyle {
    let ink: Color
    let paper: Color
    let reduced: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(paper)
            .background(ink.opacity(configuration.isPressed ? 0.80 : 1), in: .rect(cornerRadius: 12))
            .scaleEffect(configuration.isPressed && !reduced ? 0.98 : 1)
            .animation(reduced ? nil : Look.quick, value: configuration.isPressed)
    }
}

/// An explicitly illustrative empty Space, using Vane's sidebar vocabulary and mark.
private struct WelcomeSpacePreview: View {
    let tint: Color
    let dark: Bool
    let ink: Color
    let paper: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { _ in Circle().fill(ink.opacity(0.22)).frame(width: 8, height: 8) }
                }.padding(.bottom, 12)
                HStack { Image(systemName: "magnifyingglass"); Text("Search or enter URL") }
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.7))
                HStack(spacing: 8) { Image(systemName: "cloud"); Text("Personal") }
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) { Image(systemName: "plus"); Text("New Tab") }
                    .font(.system(size: 11)).foregroundStyle(ink.opacity(0.72))
                Spacer()
                HStack { Image(systemName: "sidebar.left"); Spacer(); Image(systemName: "plus") }
                    .font(.system(size: 13))
            }
            .padding(18).frame(width: 172)
            ZStack {
                paper.opacity(0.92)
                VStack(spacing: 20) {
                    Image(nsImage: WelcomeArtwork.logo).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 42, height: 48).foregroundStyle(ink.opacity(0.35))
                    Text("A fresh start.").font(.system(size: 23, design: .serif)).foregroundStyle(ink.opacity(0.6))
                }
            }.clipShape(.rect(cornerRadius: 10)).padding(.vertical, 9).padding(.trailing, 9)
        }
        .frame(height: 330)
        .background(tint.opacity(dark ? 0.3 : 0.55), in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(dark ? 0.2 : 0.09), radius: 30, x: 0, y: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of your Space color")
    }
}
