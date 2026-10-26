import SwiftUI

/// Keep keyboard focus available after a click, but only draw its indicator when
/// the user is interacting through the keyboard. One passive monitor serves all controls.
@MainActor private final class KeyboardFocusVisibility: ObservableObject {
    static let shared = KeyboardFocusVisibility()
    @Published private(set) var visible = false
    private var monitor: Any?
    private var requestedVisibility = false
    private var updateScheduled = false

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Shortcuts such as ⌘W must not reveal focus left behind by a click.
            // Preserve the current visibility; explicit focus requests still show it.
            if event.type == .keyDown,
               !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                return event
            }
            MainActor.assumeIsolated {
                self?.setVisible(event.type == .keyDown)
            }
            return event
        }
    }

    func showForKeyboard() { setVisible(true) }

    private func setVisible(_ value: Bool) {
        guard requestedVisibility != value else { return }
        requestedVisibility = value
        guard !updateScheduled else { return }
        updateScheduled = true
        // Key handlers can run during a SwiftUI update. Publish on the next turn,
        // coalescing input so a later click always wins over an earlier key press.
        DispatchQueue.main.async {
            self.updateScheduled = false
            if self.visible != self.requestedVisibility {
                self.visible = self.requestedVisibility
            }
        }
    }
}

/// Keyboard behavior for the custom surfaces that use gestures instead of native buttons.
/// Keep the focus outline inside the surface so focusing never moves neighboring controls.
private struct KeyboardAction: ViewModifier {
    let enabled: Bool
    let radius: CGFloat
    let action: () -> Void
    var previewAction: (() -> Void)?
    var requestFocus: Binding<Bool>?
    var focusChanged: ((Bool) -> Void)?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bufferedSidebarFocus) private var bufferedFocus
    @Environment(\.nativeSidebarNavigationRow) private var nativeNavigation
    @State private var focusOwner = UUID()
    @FocusState private var focused: Bool
    @ObservedObject private var focusVisibility = KeyboardFocusVisibility.shared

    private var showsOutline: Bool { focused && focusVisibility.visible }

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { _, value in
                if let bufferedFocus {
                    bufferedFocus.set(value, owner: focusOwner)
                }
                if let nativeNavigation { nativeNavigation.navigation?.focusChanged(value, token: focusOwner) }
                else { NativeSidebarNavigation.outerFocusChanged(value, token: focusOwner) }
                focusChanged?(value)
            }
            .onDisappear {
                bufferedFocus?.set(false, owner: focusOwner)
                if let nativeNavigation { nativeNavigation.navigation?.focusChanged(false, token: focusOwner) }
                else { NativeSidebarNavigation.outerFocusChanged(false, token: focusOwner) }
            }
            .onChange(of: isEnabled) { _, value in
                if !value { focused = false }
            }
            .onChange(of: requestFocus?.wrappedValue, initial: true) { _, requested in
                guard requested == true, enabled, isEnabled else { return }
                if let nativeNavigation, let navigation = nativeNavigation.navigation {
                    navigation.requestFocus(token: focusOwner, row: nativeNavigation.row)
                } else {
                    focusVisibility.showForKeyboard()
                    focused = true
                }
                requestFocus?.wrappedValue = false
            }
            .background {
                NativeSidebarNavigationControl(row: nativeNavigation, token: focusOwner, enabled: enabled && isEnabled) {
                    if NativeSidebarNavigation.diagnosticsEnabled { print("NATIVE_NAV swiftUIFocusRequest row=\(nativeNavigation?.row ?? "outer") token=\(focusOwner) before=\(focused)") }
                    focusVisibility.showForKeyboard()
                    focused = true
                }
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                guard focused, enabled, isEnabled,
                      press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                let backwards = press.modifiers.contains(.shift)
                if let navigation = nativeNavigation?.navigation {
                    return navigation.move(from: focusOwner, backwards: backwards) ? .handled : .ignored
                }
                return NativeSidebarNavigation.moveOuter(from: focusOwner, backwards: backwards) ? .handled : .ignored
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { press in
                guard focused, enabled, isEnabled, press.modifiers.isEmpty else { return .ignored }
                focusVisibility.showForKeyboard()
                InteractionSounds.play(.press)
                action()
                return .handled
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { press in
                guard focused, enabled, isEnabled, press.modifiers.intersection([.command, .control, .option, .shift]) == .option, let previewAction else { return .ignored }
                focusVisibility.showForKeyboard()
                previewAction()
                return .handled
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(showsOutline ? 1 : 0)
                    .padding(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: showsOutline)
    }
}

/// Native SwiftUI Buttons already provide activation. Register only their focus
/// request/geometry so Tab does not omit them between custom row surfaces.
private struct NativeSidebarButtonNavigation: ViewModifier {
    var focusChanged: ((Bool) -> Void)?
    @Environment(\.nativeSidebarNavigationRow) private var navigationRow
    @Environment(\.bufferedSidebarFocus) private var bufferedFocus
    @Environment(\.isEnabled) private var enabled
    @State private var token = UUID()
    @FocusState private var focused: Bool
    // These controls retain native Button eligibility: none adds .focusable().
    // With Full Keyboard Access off, Tab skips ordinary native buttons.
    private var acceptsTab: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .background {
                NativeSidebarNavigationControl(row: navigationRow, token: token, enabled: acceptsTab) {
                    guard acceptsTab else { return }
                    KeyboardFocusVisibility.shared.showForKeyboard()
                    focused = true
                }
            }
            .onChange(of: focused) { _, value in
                bufferedFocus?.set(value, owner: token)
                if let navigationRow { navigationRow.navigation?.focusChanged(value, token: token) }
                else { NativeSidebarNavigation.outerFocusChanged(value, token: token) }
                focusChanged?(value)
            }
            .onDisappear {
                bufferedFocus?.set(false, owner: token)
                if let navigationRow { navigationRow.navigation?.focusChanged(false, token: token) }
                else { NativeSidebarNavigation.outerFocusChanged(false, token: token) }
                focusChanged?(false)
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                guard focused, acceptsTab,
                      press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                let backwards = press.modifiers.contains(.shift)
                if let navigation = navigationRow?.navigation {
                    return navigation.move(from: token, backwards: backwards) ? .handled : .ignored
                }
                return NativeSidebarNavigation.moveOuter(from: token, backwards: backwards) ? .handled : .ignored
            }
    }
}

extension View {
    func nativeSidebarKeyboardControl(focusChanged: ((Bool) -> Void)? = nil) -> some View {
        modifier(NativeSidebarButtonNavigation(focusChanged: focusChanged))
    }
    func vaneKeyboardAction(enabled: Bool = true, radius: CGFloat = Look.pillRadius,
                            requestFocus: Binding<Bool>? = nil,
                            previewAction: (() -> Void)? = nil,
                            focusChanged: ((Bool) -> Void)? = nil,
                            action: @escaping () -> Void) -> some View {
        modifier(KeyboardAction(enabled: enabled, radius: radius, action: action, previewAction: previewAction,
                                requestFocus: requestFocus, focusChanged: focusChanged))
    }
}
