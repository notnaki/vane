import SwiftUI

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

    func body(content: Content) -> some View {
        content
            .focusable(enabled && isEnabled)
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: requestFocus?.wrappedValue, initial: true) { _, requested in
                guard requested == true, enabled, isEnabled else { return }
                focused = true
                requestFocus?.wrappedValue = false
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { press in
                guard focused, enabled, isEnabled, press.modifiers.isEmpty else { return .ignored }
                InteractionSounds.play(.press)
                action()
                return .handled
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(focused ? 1 : 0)
                    .padding(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: focused)
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
