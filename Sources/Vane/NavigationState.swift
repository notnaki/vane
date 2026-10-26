import AppKit
import WebKit

/// Per-tab navigation ownership. URLs are not document identities: a reload, a form
/// response and an error page can all have the same URL and different lifetimes.
@MainActor final class NavigationState {
    var active: WKNavigation?
    private let retired = NSHashTable<WKNavigation>.weakObjects()
    var finished = true
    var simulated: WKNavigation?
    let simulatedItems = NSHashTable<WKBackForwardListItem>.weakObjects()
    var lastHistoryURL: URL?
    var restoringHistory = false
    var receivedResponse = false
    private struct PDFTitleResponse {
        let navigation: WKNavigation
        let url: URL
        let filename: String
    }
    private var pendingPDFTitle: PDFTitleResponse?
    private var committedPDFTitle: (url: URL, filename: String)?
    private var generation = UUID()
    var policyGeneration: UUID { generation }
    private var prompt: NSAlert?
    private weak var promptWindow: NSWindow?

    func isRetired(_ navigation: WKNavigation) -> Bool { retired.contains(navigation) }

    func accepts(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else { return false }
        return active === navigation && !finished
    }

    /// Claim commands before WebKit has delivered their start callback. Redirect policy
    /// actions carry the same identity and must not retire their own navigation.
    @discardableResult func expect(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, !retired.contains(navigation), active !== navigation else { return false }
        if let active { retired.add(active) }
        cancelPrompt()
        active = navigation
        finished = false
        receivedResponse = false
        pendingPDFTitle = nil
        return true
    }

    func begin(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, !retired.contains(navigation) else { return false }
        if active === navigation { return !finished }
        return expect(navigation)
    }

    func invalidate(preservingDocument: Bool = false) {
        if let active { retired.add(active) }
        cancelPrompt()
        active = nil
        finished = true
        pendingPDFTitle = nil
        if !preservingDocument { committedPDFTitle = nil }
    }

    /// Response metadata is provisional until this exact navigation commits its final URL.
    func receiveDocumentResponse(_ response: URLResponse, navigation: WKNavigation?) {
        guard let navigation, accepts(navigation) else { return }
        pendingPDFTitle = nil
        guard let url = response.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              response.mimeType?.lowercased() == "application/pdf",
              let filename = response.suggestedFilename,
              !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingPDFTitle = PDFTitleResponse(navigation: navigation, url: url, filename: filename)
    }

    func commitDocumentResponse(_ navigation: WKNavigation?, at url: URL?) {
        guard let navigation, accepts(navigation) else { return }
        let response = pendingPDFTitle
        pendingPDFTitle = nil
        // A new document replaces the old response even when its URL is unchanged.
        committedPDFTitle = nil
        guard let response, let url, response.navigation === navigation,
              Self.sameResponseDocument(response.url, url) else { return }
        committedPDFTitle = (url, response.filename)
    }

    func suggestedFilename(for url: URL?) -> String? {
        guard let url, let committedPDFTitle,
              Self.sameResponseDocument(committedPDFTitle.url, url) else { return nil }
        return committedPDFTitle.filename
    }

    private static func sameResponseDocument(_ first: URL, _ second: URL) -> Bool {
        var a = URLComponents(url: first, resolvingAgainstBaseURL: false)
        var b = URLComponents(url: second, resolvingAgainstBaseURL: false)
        a?.fragment = nil; b?.fragment = nil
        return a != nil && a == b
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

    func confirmResubmission(tab: Tab, web: WKWebView, requestGeneration: UUID) async -> Bool {
        guard generation == requestGeneration, prompt == nil, tab.existingWeb === web, let window = web.window,
              !web.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil else { return false }
        let generation = requestGeneration
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
