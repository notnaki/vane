import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Translate Page: the page's own text nodes rewritten in place by Apple's on-device
/// Translation framework, and put back by Show Original.
///
/// Only `Text.data` is ever written — no element is added, removed or restyled, and form
/// fields, code and anything marked `translate="no"` are skipped — so layout and inputs
/// are the page's own. Nothing is persisted, which is also what a private window needs.
/// ponytail: no "offer to translate" bar and so no "Never translate this site" list; add
/// both together the day the offer exists. Text the page adds after the walk stays as it
/// came (a long feed keeps its new items in the original language) — upgrade path is a
/// MutationObserver feeding the same batches.
@MainActor final class PageTranslation: ObservableObject {
    static let shared = PageTranslation()
    /// Tabs showing a translation. Cleared on navigation by `forget`.
    @Published private(set) var tabs: Set<UUID> = []
    /// The window whose `.translationTask` should run, and what it runs with. A
    /// configuration per window, so the one being asked is the one that shows the download
    /// sheet when a language is not installed yet.
    @Published fileprivate var configs: [ObjectIdentifier: TranslationSession.Configuration] = [:]
    fileprivate var pending: [ObjectIdentifier: (tab: Tab, generation: UUID, texts: [String])] = [:]

    /// Page scripts can replace builtins in their own world; the walk lives in another.
    static let world = WKContentWorld.world(name: "vane-translate")
    nonisolated static let batchSize = 50

    static func isOn(_ tab: Tab?) -> Bool { tab.map { shared.tabs.contains($0.id) } ?? false }
    static func title(for tab: Tab?) -> String { isOn(tab) ? "Show Original" : "Translate Page" }
    static func forget(tab: Tab) { shared.tabs.remove(tab.id) }

    static func toggle(_ tab: Tab?, in store: TabStore? = Windows.current) {
        guard let tab, tab.easelID == nil, let web = tab.existingWeb else { return }
        if isOn(tab) {
            shared.tabs.remove(tab.id)
            web.evaluateJavaScript(restoreJS, in: nil, in: world) { _ in }
            SiteChanges.shared.bump()
            return
        }
        guard let store else { return }
        let generation = tab.readingDocumentGeneration
        Task {
            guard let result = try? await web.callAsyncJavaScript(collectJS, contentWorld: world) as? [String: Any],
                  let texts = result["texts"] as? [String], !texts.isEmpty,
                  tab.readingDocumentGeneration == generation else {
                Toasts.show("Nothing on this page to translate", in: store); return
            }
            let target = preferredLanguage()
            let source = sourceLanguage(lang: result["lang"] as? String, sample: texts)
            if let source, sameLanguage(source, target) {
                Toasts.show("This page is already in \(name(of: target))", in: store); return
            }
            if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported {
                Toasts.show("Translation from \(name(of: source)) isn't available", in: store); return
            }
            let window = ObjectIdentifier(store)
            shared.pending[window] = (tab, generation, texts)
            let config = TranslationSession.Configuration(source: source, target: target)
            // An equal configuration would not restart the task; invalidating it does.
            if shared.configs[window] == config { shared.configs[window]?.invalidate() }
            else { shared.configs[window] = config }
        }
    }

    /// Runs inside `.translationTask` for `window`. Batches go back to the page as they
    /// come, so a long page fills in from the top rather than all at once at the end. The
    /// session never leaves this function: it is not `Sendable`, so only plain strings
    /// cross to the main actor.
    fileprivate nonisolated static func run(_ session: TranslationSession, window: ObjectIdentifier) async {
        guard let (tab, generation, texts) = await begin(window) else { return }
        do {
            for start in stride(from: 0, to: texts.count, by: batchSize) {
                let requests = texts[start..<min(start + batchSize, texts.count)].enumerated().map {
                    TranslationSession.Request(sourceText: $1, clientIdentifier: String(start + $0))
                }
                var out: [String: String] = [:]
                for r in try await session.translations(from: requests) {
                    if let id = r.clientIdentifier { out[id] = r.targetText }
                }
                guard await apply(out, to: tab, generation: generation) else { return }
            }
        } catch {
            if !Task.isCancelled { await failed(tab) }
        }
    }

    private static func begin(_ window: ObjectIdentifier) -> (Tab, UUID, [String])? {
        guard let job = shared.pending.removeValue(forKey: window), job.tab.existingWeb != nil,
              job.tab.readingDocumentGeneration == job.generation else { return nil }
        shared.tabs.insert(job.tab.id)
        SiteChanges.shared.bump()
        return (job.tab, job.generation, job.texts)
    }

    /// False once the tab navigated or Show Original was pressed while a batch was out.
    private static func apply(_ batch: [String: String], to tab: Tab, generation: UUID) async -> Bool {
        guard tab.readingDocumentGeneration == generation, isOn(tab), let web = tab.existingWeb else { return false }
        _ = try? await web.callAsyncJavaScript(applyJS, arguments: ["batch": batch], contentWorld: world)
        return true
    }

    private static func failed(_ tab: Tab) {
        guard isOn(tab) else { return }
        shared.tabs.remove(tab.id)
        tab.existingWeb?.evaluateJavaScript(restoreJS, in: nil, in: world) { _ in }
        SiteChanges.shared.bump()
        Toasts.show("Couldn't translate this page")
    }

    // MARK: - Languages

    static func preferredLanguage() -> Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// The text decides, and the page's `lang` only breaks a tie: plenty of templates ship
    /// `lang="en"` over pages in another language.
    nonisolated static func sourceLanguage(lang: String?, sample: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.joined(separator: "\n").prefix(4000)))
        if let detected = recognizer.dominantLanguage, detected != .undetermined {
            return Locale.Language(identifier: detected.rawValue)
        }
        guard let lang = lang?.trimmingCharacters(in: .whitespaces), !lang.isEmpty else { return nil }
        return Locale.Language(identifier: lang)
    }

    /// Same language and, where both say, the same script: Simplified and Traditional
    /// Chinese are a translation apart; en-GB and en-US are not.
    nonisolated static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let x = a.languageCode, x == b.languageCode else { return false }
        guard let s = a.script, let t = b.script else { return true }
        return s == t
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    // MARK: - Page scripts

    /// Collects every rendered text node worth translating and remembers it in this world,
    /// with its original text and surrounding whitespace, for `applyJS` and `restoreJS`.
    static let collectJS = """
    const prior = globalThis.__vaneTranslation;
    if (prior) prior.nodes.forEach((n, i) => { if (n.data === prior.done[i]) n.data = prior.originals[i]; });
    const skip = 'script,style,noscript,textarea,input,select,option,code,pre,kbd,samp,var,svg,math,template,' +
      '[contenteditable]:not([contenteditable="false"]),[translate="no"],.notranslate';
    const nodes = [], originals = [], lead = [], trail = [], texts = [];
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(n) {
      const p = n.parentElement;
      if (!p || !/\\p{L}/u.test(n.data) || p.closest(skip) || p.isContentEditable) return NodeFilter.FILTER_REJECT;
      if (p.checkVisibility && !p.checkVisibility()) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }});
    for (let n; (n = walker.nextNode()) && nodes.length < 5000;) {
      const m = n.data.match(/^(\\s*)([\\s\\S]*?)(\\s*)$/);
      nodes.push(n); originals.push(n.data); lead.push(m[1]); trail.push(m[3]); texts.push(m[2]);
    }
    globalThis.__vaneTranslation = { nodes, originals, lead, trail, done: originals.slice() };
    return { lang: document.documentElement.lang || '', texts };
    """

    /// `batch` maps a node's index to its translation. A node the page rewrote meanwhile
    /// keeps the page's text.
    static let applyJS = """
    const t = globalThis.__vaneTranslation;
    if (!t) return;
    for (const [k, text] of Object.entries(batch)) {
      const i = Number(k), n = t.nodes[i];
      if (!n || !n.isConnected || n.data !== t.originals[i]) continue;
      n.data = t.lead[i] + text + t.trail[i];
      t.done[i] = n.data;
    }
    """

    static let restoreJS = """
    (() => {
      const t = globalThis.__vaneTranslation;
      if (!t) return;
      t.nodes.forEach((n, i) => { if (n.data === t.done[i]) n.data = t.originals[i]; });
      delete globalThis.__vaneTranslation;
    })();
    """

    // MARK: - check

    static func check() -> [(String, Bool)] {
        let en = Locale.Language(identifier: "en-US")
        let german = sourceLanguage(lang: "en", sample: ["Die Katze sitzt auf der Matte und schläft den ganzen Tag."])
        return [
            ("the text decides over a wrong lang attribute", german?.languageCode == "de"),
            ("lang is the fallback when the text says nothing", sourceLanguage(lang: "ja", sample: ["123"])?.languageCode == "ja"),
            ("no text and no lang is unknown", sourceLanguage(lang: " ", sample: []) == nil),
            ("regional variants are the same language", sameLanguage(Locale.Language(identifier: "en-GB"), en)),
            ("another language is not", !sameLanguage(Locale.Language(identifier: "fr"), en)),
            ("Simplified and Traditional Chinese differ",
             !sameLanguage(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant"))),
            ("menu title follows state", title(for: nil) == "Translate Page"),
        ]
    }
}

/// Hosts the Translation framework's session for one window. The framework only hands out
/// a session that can download a missing language from inside a SwiftUI view, and this is
/// that view's modifier.
struct PageTranslationHost: ViewModifier {
    let store: TabStore
    @ObservedObject private var translation = PageTranslation.shared

    func body(content: Content) -> some View {
        let window = ObjectIdentifier(store)
        content.translationTask(translation.configs[window], action: Self.action(window))
    }

    /// Built outside the view's main-actor body, so the session stays off the main actor.
    private nonisolated static func action(_ window: ObjectIdentifier) -> (TranslationSession) async -> Void {
        { session in await PageTranslation.run(session, window: window) }
    }
}
