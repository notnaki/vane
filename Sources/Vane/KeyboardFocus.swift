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
    var requestFocus: Binding<Bool>?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @ObservedObject private var focusVisibility = KeyboardFocusVisibility.shared

    private var showsOutline: Bool { focused && focusVisibility.visible }

    func body(content: Content) -> some View {
        content
            .focusable(enabled && isEnabled)
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: requestFocus?.wrappedValue, initial: true) { _, requested in
                guard requested == true, enabled, isEnabled else { return }
                focusVisibility.showForKeyboard()
                focused = true
                requestFocus?.wrappedValue = false
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { press in
                guard focused, enabled, isEnabled, press.modifiers.isEmpty else { return .ignored }
                focusVisibility.showForKeyboard()
                InteractionSounds.play(.press)
                action()
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

extension View {
    func vaneKeyboardAction(enabled: Bool = true, radius: CGFloat = Look.pillRadius,
                            requestFocus: Binding<Bool>? = nil,
                            action: @escaping () -> Void) -> some View {
        modifier(KeyboardAction(enabled: enabled, radius: radius, action: action,
                                requestFocus: requestFocus))
    }
}
