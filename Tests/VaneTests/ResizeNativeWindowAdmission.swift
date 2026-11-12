import AppKit
import WebKit

/// Admit the exact initial native owner; never await a resized outcome here.
@MainActor enum ResizeNativeWindowAdmission {
    static func wait(_ window: NSWindow, web: WKWebView, layout: Bool = false) async throws {
        var states = Set<String>()
        var occlusionRecoveryPending = false
        try await compatibilityWait {
            let state = "running=\(NSApp.isRunning) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) key=\(window.isKeyWindow) exact=\(NSApp.keyWindow === window) visible=\(window.isVisible) occluded=\(!window.occlusionState.contains(.visible)) policy=\(NSApp.activationPolicy().rawValue) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) expected=\(ProcessInfo.processInfo.processIdentifier)"
            if states.count < 16, states.insert(state).inserted { print("RESIZE_CAPTURE_ADMISSION \(state)") }
            if NSApp.isHidden { NSApp.unhide(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if window.occlusionState.contains(.visible) { occlusionRecoveryPending = false }
            if !window.isVisible || !window.isKeyWindow || NSApp.keyWindow !== window || !window.occlusionState.contains(.visible) {
                // Match SidebarSnapshot's public recovery: re-keying an already
                // key window alone does not refresh stale native occlusion.
                if window.isVisible, window.isKeyWindow, !window.occlusionState.contains(.visible),
                   !occlusionRecoveryPending {
                    window.orderOut(nil)
                    occlusionRecoveryPending = true
                }
                window.makeKeyAndOrderFront(nil)
            }
            if layout { window.contentView?.layoutSubtreeIfNeeded() }
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window
                && window.isVisible && window.occlusionState.contains(.visible)
                && web.window === window && web.bounds.width > 100
        }
    }
}
