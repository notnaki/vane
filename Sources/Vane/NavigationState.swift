import AppKit
import WebKit

/// Per-tab navigation ownership. URLs are not document identities: a reload, a form
/// response and an error page can all have the same URL and different lifetimes.
@MainActor final class NavigationState {
    var active: WKNavigation?
    var finished = true
    var simulated: WKNavigation?
    let simulatedItems = NSHashTable<WKBackForwardListItem>.weakObjects()
    var lastHistoryURL: URL?
    var restoringHistory = false
    var receivedResponse = false
    private var generation = UUID()
    private var prompt: NSAlert?
    private weak var promptWindow: NSWindow?

    func accepts(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return false }
        return active === navigation && !finished
    }

    func begin(_ navigation: WKNavigation?) {
        cancelPrompt()
        active = navigation
        finished = false
        receivedResponse = false
    }

    func invalidate() {
        cancelPrompt()
        active = nil
        finished = true
    }

    func cancelPrompt() {
        generation = UUID()
        if let prompt, let window = promptWindow {
            window.endSheet(prompt.window, returnCode: .abort)
        }
        prompt = nil
        promptWindow = nil
    }

    static func needsResubmissionConsent(_ action: WKNavigationAction) -> Bool {
        if action.navigationType == .formResubmitted { return true }
        // macOS 27 reports POST reloads as .reload rather than .formResubmitted.
        let method = action.request.httpMethod?.uppercased() ?? "GET"
        return [.reload, .backForward].contains(action.navigationType)
            && !["GET", "HEAD"].contains(method)
    }

    func confirmResubmission(tab: Tab, web: WKWebView) async -> Bool {
        guard prompt == nil, tab.existingWeb === web, let window = web.window,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return false }
        let generation = generation
        let presentation = tab.presentationGeneration
        let alert = NSAlert()
        alert.messageText = "Send this form again?"
        alert.informativeText = "This page was created by submitting a form. Continuing will send the form again and may repeat a purchase or another action."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Send Again").keyEquivalent = ""
        prompt = alert
        promptWindow = window
        let answer = await alert.beginSheetModal(for: window)
        if prompt === alert { prompt = nil; promptWindow = nil }
        return answer == .alertSecondButtonReturn && self.generation == generation
            && tab.presentationGeneration == presentation && tab.existingWeb === web
            && web.window === window && !web.isHiddenOrHasHiddenAncestor
    }
}
