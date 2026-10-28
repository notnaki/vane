import AppKit
import SwiftUI

/// A native, nonmodal permission bubble. The policy owner still validates the document
/// after this returns; closing the bubble is never a saved denial.
@MainActor final class SitePermissionPrompt: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    let messageText: String
    let informativeText: String
    let persistentAllowTitle: String
    private let symbol: String
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?

    init(message: String, information: String, persistentAllowTitle: String, symbol: String) {
        self.messageText = message
        self.informativeText = information
        self.persistentAllowTitle = persistentAllowTitle
        self.symbol = symbol
        super.init()
        popover.behavior = .semitransient
        popover.delegate = self
    }

    func present(in window: NSWindow, tabID: UUID) async -> NSApplication.ModalResponse {
        guard let content = window.contentView, window.isVisible else { return .abort }
        let anchor = SitePermissionAnchor.find(tabID: tabID, in: content)
        let positioningView = anchor ?? content
        let bounds = positioningView.bounds
        // A collapsed sidebar or a script-created window may have no address control.
        // Keep the bubble in the requester's chrome instead of pointing into page content.
        let rect = anchor != nil ? bounds : NSRect(
            x: bounds.minX + min(150, bounds.width / 2),
            y: positioningView.isFlipped ? bounds.minY : bounds.maxY - 1,
            width: 1, height: 1)
        let view = PermissionPromptContent(message: messageText, information: informativeText,
                                           persistentAllowTitle: persistentAllowTitle, icon: symbol) {
            [weak self] in self?.finish($0)
        }
            .frame(width: min(236, max(180, content.bounds.width - 24)))
        let controller = NSHostingController(rootView: view)
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.animates = !Motion.reduced
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            popover.show(relativeTo: rect, of: positioningView, preferredEdge: .minY)
            if window.isKeyWindow, let bubble = controller.view.window {
                bubble.makeKey()
                bubble.makeFirstResponder(controller.view)
            }
            if !popover.isShown { finish(.abort) }
        }
    }

    func finish(_ response: NSApplication.ModalResponse) {
        guard let continuation else { return }
        self.continuation = nil
        popover.animates = !Motion.reduced
        popover.close()
        continuation.resume(returning: response)
    }

    func popoverDidClose(_ notification: Notification) { finish(.abort) }
}

private struct PermissionPromptContent: View {
    let message: String
    let information: String
    let persistentAllowTitle: String
    let icon: String
    let respond: (NSApplication.ModalResponse) -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { respond(.abort) } label: {
                    Text("Not Now")
                }
                .buttonStyle(PermissionButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button { respond(.alertFirstButtonReturn) } label: {
                    Text("Allow")
                }
                .buttonStyle(PermissionButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
                .help("Allow Once, until this tab navigates or closes. More choices are available in the context menu.")
                .contextMenu {
                    Button("Allow Once") { respond(.alertFirstButtonReturn) }
                    Button(persistentAllowTitle) { respond(.alertSecondButtonReturn) }
                    Divider()
                    Button("Don’t Allow") { respond(.alertThirdButtonReturn) }
                }
                .accessibilityAction(named: persistentAllowTitle) { respond(.alertSecondButtonReturn) }
                .accessibilityAction(named: "Don’t Allow") { respond(.alertThirdButtonReturn) }
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.primary.opacity(0.8))
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Site permission")
        .accessibilityHint(information)
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed, emphasized: emphasized)
    }

    private struct Face: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let emphasized: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ObservedObject private var batterySaver = BatterySaver.shared
        @State private var hovering = false
        private var reduced: Bool { reduceMotion || batterySaver.isActive }

        var body: some View {
            label
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(.primary.opacity(pressed ? 0.3 : hovering ? 0.24 : emphasized ? 0.21 : 0.04),
                            in: .rect(cornerRadius: 6))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    } else if emphasized {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
                    }
                }
                .contentShape(.rect(cornerRadius: 6))
                .onHover { hovering = $0 }
                .animation(reduced ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduced ? nil : .easeOut(duration: 0.08), value: pressed)
                .transaction { if reduced { $0.disablesAnimations = true } }
        }
    }
}

/// An invisible AppKit rectangle in the address control. Resolve it in the requesting
/// window, since a shared tab can also have controls in windows showing its snapshot.
struct SitePermissionAnchor: NSViewRepresentable {
    let tabID: UUID

    func makeNSView(context: Context) -> NSView { Anchor(tabID: tabID) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Anchor)?.tabID = tabID }

    @MainActor private final class Anchor: NSView {
        var tabID: UUID
        init(tabID: UUID) { self.tabID = tabID; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func find(tabID: UUID, in view: NSView) -> NSView? {
        guard !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        if let anchor = view as? Anchor, anchor.tabID == tabID { return anchor }
        for child in view.subviews {
            if let anchor = find(tabID: tabID, in: child) { return anchor }
        }
        return nil
    }
}
