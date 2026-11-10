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

/// One exact native keyboard/AX endpoint for the address surface. It never
/// discovers a SwiftUI responder or borrows the surrounding browser's host.
@MainActor final class MountedAddressButton: NSButton {
    weak var store: TabStore?
    var token = UUID()
    var perform: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var addressValue = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isTransparent = true
        isBordered = false
        focusRingType = .none
        keyEquivalent = ""
        // The view is the exact keyboard/AX endpoint. The button's default cell
        // must not appear as a second actionable child or own AX focus instead.
        cell?.setAccessibilityElement(false)
        target = self
        action = #selector(activateAddress)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Address and Search" }
    override func accessibilityValue() -> Any? { addressValue }
    override func accessibilityHelp() -> String? { "Opens the search bar to type a website address or a search." }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func accessibilityPerformPress() -> Bool {
        guard available, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        activateAddress()
        return true
    }

    private var available: Bool {
        guard isEnabled, let store, let window, store.window === window,
              store.profileVisible, (store.isLittle || store.sidebarShown || store.sidebarPeeking), !store.libraryOpen,
              !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else { return false }
        return store.mountedAddressEndpoint === self
    }
    private var mayFocus: Bool {
        available && store?.palette == nil && window?.attachedSheet == nil
            && NSApp.modalWindow == nil && NSApp.isActive && window?.isKeyWindow == true
            && NSApp.keyWindow === window
    }
    override var acceptsFirstResponder: Bool { mayFocus }

    @discardableResult func takeFocus(from responder: NSResponder?) -> Bool {
        guard mayFocus, let window, window.firstResponder === responder,
              window.makeFirstResponder(self), window.firstResponder === self else { return false }
        KeyboardFocusVisibility.shared.showForKeyboard()
        observeFocus()
        return true
    }
    private func observeFocus() {
        let focused = mayFocus && window?.firstResponder === self
        NativeSidebarNavigation.outerFocusChanged(focused, token: token)
        focusChanged?(focused)
    }
    private func observeAfterCommit() {
        DispatchQueue.main.async { [weak self] in self?.observeFocus() }
    }
    override func becomeFirstResponder() -> Bool {
        guard mayFocus, super.becomeFirstResponder() else { return false }
        // AppKit installs firstResponder after this callback returns.
        observeAfterCommit()
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        observeAfterCommit()
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerOwner()
        observeAfterCommit()
    }
    func registerOwner() {
        guard let store else { return }
        if let window, store.window === window { store.mountedAddressEndpoint = self }
        else if store.mountedAddressEndpoint === self { store.mountedAddressEndpoint = nil }
    }
    func retire() {
        if store?.mountedAddressEndpoint === self { store?.mountedAddressEndpoint = nil }
        // The separate geometry anchor owns outer-registry registration. Its
        // dismantle revokes that entry; rebinding this endpoint must not erase
        // a registration the anchor already refreshed for a replacement store.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        perform = nil; focusChanged = nil
        setAccessibilityCustomActions(nil)
        store = nil
    }
    @objc private func activateAddress() {
        guard available, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        KeyboardFocusVisibility.shared.showForKeyboard()
        InteractionSounds.play(.press)
        perform?()
    }
    func performAccessibilityAction(_ action: () -> Void) -> Bool {
        guard available, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        action()
        return true
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if [36, 49, 76].contains(event.keyCode) {
            if modifiers.isEmpty { activateAddress() }
            return
        }
        if event.keyCode == 48, modifiers.subtracting(.shift).isEmpty {
            guard mayFocus, window?.firstResponder === self else { return }
            observeFocus()
            if !NativeSidebarNavigation.moveOuter(from: token, backwards: modifiers.contains(.shift)) {
                if modifiers.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            }
            return
        }
        nextResponder?.keyDown(with: event)
    }
}

private struct MountedAddressSurface: NSViewRepresentable {
    let store: TabStore
    let token: UUID
    let enabled: Bool
    let value: String
    let action: () -> Void
    let customActions: [(String, () -> Void)]
    let focusChanged: (Bool) -> Void
    func makeNSView(context: Context) -> MountedAddressButton { MountedAddressButton(frame: .zero) }
    func updateNSView(_ view: MountedAddressButton, context: Context) {
        if view.store !== store || view.token != token { view.retire() }
        view.store = store; view.token = token; view.isEnabled = enabled
        view.perform = action; view.focusChanged = focusChanged
        view.addressValue = value
        view.setAccessibilityCustomActions(customActions.map { name, action in
            NSAccessibilityCustomAction(name: name) { [weak view] in
                view?.performAccessibilityAction(action) ?? false
            }
        })
        view.registerOwner()
        if !enabled, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }
    static func dismantleNSView(_ view: MountedAddressButton, coordinator: ()) { view.retire() }
}

private struct AddressKeyboardAction: ViewModifier {
    let store: TabStore
    let value: String
    let action: () -> Void
    let customActions: [(String, () -> Void)]
    let focusChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token = UUID()
    @State private var focused = false
    @ObservedObject private var visibility = KeyboardFocusVisibility.shared
    func body(content: Content) -> some View {
        content
            .background {
                MountedAddressSurface(store: store, token: token, enabled: enabled, value: value,
                                      action: action, customActions: customActions) { value in
                    if focused != value { focused = value; focusChanged(value) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background {
                // Preserve the existing outer key-loop geometry and lifecycle.
                NativeSidebarNavigationControl(row: nil, token: token, enabled: enabled) { [weak store] in
                    guard let endpoint = store?.mountedAddressEndpoint else { return }
                    endpoint.takeFocus(from: endpoint.window?.firstResponder)
                }
            }
            .onChange(of: store.chromeFocusRequested, initial: true) { _, requested in
                guard requested else { return }
                if let endpoint = store.mountedAddressEndpoint {
                    endpoint.takeFocus(from: endpoint.window?.firstResponder)
                }
                store.chromeFocusRequested = false
            }
            .overlay {
                RoundedRectangle(cornerRadius: Look.pillRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(focused && visibility.visible ? 1 : 0)
                    .padding(1).allowsHitTesting(false).accessibilityHidden(true)
            }
            .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: focused && visibility.visible)
    }
}

extension View {
    func addressKeyboardAction(store: TabStore, value: String,
                               customActions: [(String, () -> Void)],
                               focusChanged: @escaping (Bool) -> Void,
                               action: @escaping () -> Void) -> some View {
        modifier(AddressKeyboardAction(store: store, value: value, action: action,
                                       customActions: customActions, focusChanged: focusChanged))
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
