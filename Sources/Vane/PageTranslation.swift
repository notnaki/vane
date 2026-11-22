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
/// are the page's own. The only thing persisted is the per-profile "Never translate this
/// site" list, and a private window neither offers nor writes it.
/// ponytail: text the page adds after the walk stays as it came (a long feed keeps its new
/// items in the original language) — upgrade path is a MutationObserver feeding the same
/// batches.
@MainActor final class PageTranslation: ObservableObject {
    static let shared = PageTranslation()
    /// Tabs showing a translation, each with the job filling it in. Cleared when a new
    /// document commits (`forget`), so a link that turns into a download leaves it alone.
    @Published private(set) var tabs: [UUID: UUID] = [:]
    /// "Translate this page?", per tab, until answered, five minutes pass, or the tab
    /// commits another document.
    @Published fileprivate(set) var offers: [UUID: Offer] = [:] {
        didSet {
            for (tab, offer) in offers where oldValue[tab] != offer {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    if self?.offers[tab] == offer { self?.offers[tab] = nil }
                }
            }
        }
    }
    /// Per tab, the site (`site(_:)`) the user last answered while in it: true after
    /// Translate, so later pages there translate themselves, false after Not now or Show
    /// Original, so they are not offered again. Dropped on a new site and on release.
    fileprivate var answered: [UUID: (site: String, translate: Bool)] = [:]
    /// The window whose `.translationTask` should run, and what it runs with. A
    /// configuration per window, so the one being asked is the one that shows the download
    /// sheet when a language is not installed yet.
    @Published fileprivate var configs: [ObjectIdentifier: TranslationSession.Configuration] = [:]
    fileprivate(set) var pending: [ObjectIdentifier: Job] = [:]
    /// The job each window's session last began, so one it stopped for a newer job reads
    /// as cancelled even when the restart ended it with an error instead.
    private var running: [ObjectIdentifier: UUID] = [:]

    struct Job: Sendable { let tab: Tab; let id = UUID(); let texts: [String] }
    struct Offer: Equatable { let id = UUID(); let host: String; let language: String }

    /// Page scripts can replace builtins in their own world; the walk lives in another.
    static let world = WKContentWorld.world(name: "vane-translate")
    nonisolated static let batchSize = 50

    static func isOn(_ tab: Tab?) -> Bool { tab.map { shared.tabs[$0.id] != nil } ?? false }
    static func title(for tab: Tab?) -> String { isOn(tab) ? "Show Original" : "Translate Page" }
    /// On main-frame commit and on release: the new document is untranslated and unoffered.
    /// Release also forgets the site answered in the tab.
    static func forget(tab: Tab, released: Bool = false) {
        shared.tabs[tab.id] = nil
        shared.offers[tab.id] = nil
        shared.pending = shared.pending.filter { $0.value.tab !== tab }
        if released { shared.answered[tab.id] = nil }
    }

    private static func site(of tab: Tab) -> String? { tab.existingWeb?.url?.host().map(site) }

    /// `automatic` is a later page of a site the user chose to translate: it never toasts
    /// "nothing to translate" or "already in", and offers instead of taking a window's
    /// session from another tab.
    static func toggle(_ tab: Tab?, in store: TabStore? = Windows.current, automatic: Bool = false) {
        guard let tab, tab.easelID == nil, let web = tab.existingWeb else { return }
        shared.offers[tab.id] = nil
        if isOn(tab) {
            shared.tabs[tab.id] = nil
            if let s = site(of: tab) { shared.answered[tab.id] = (s, false) }
            web.evaluateJavaScript(restoreJS, in: nil, in: world) { _ in }
            SiteChanges.shared.bump()
            return
        }
        guard let store else { return }
        let generation = tab.readingDocumentGeneration
        Task {
            let result = try? await web.callAsyncJavaScript(collectJS, contentWorld: world) as? [String: Any]
            // A download or a 204 that began meanwhile is not "nothing to translate".
            guard tab.readingDocumentGeneration == generation else { return }
            guard let result, let texts = result["texts"] as? [String], !texts.isEmpty else {
                if !automatic { Toasts.show("Nothing on this page to translate", in: store) }
                return
            }
            let target = preferredLanguage()
            let source = sourceLanguage(lang: result["lang"] as? String, sample: texts)
            if let source, sameLanguage(source, target) {
                if !automatic { Toasts.show("This page is already in \(name(of: target))", in: store) }
                return
            }
            if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported {
                Toasts.show("Translation from \(name(of: source)) isn't available", in: store); return
            }
            // The awaits above can outlast a navigation; a job for the old text must not land.
            guard tab.readingDocumentGeneration == generation else { return }
            let window = ObjectIdentifier(store)
            if automatic, busy(window, besides: tab) {
                if let source, let host = web.url?.host() {
                    shared.offers[tab.id] = Offer(host: host, language: name(of: source))
                }
                return
            }
            // A job still running in this window is cancelled by the new configuration
            // below; `stopped` puts its page back and says so.
            shared.pending[window] = Job(tab: tab, texts: texts)
            if let s = site(of: tab) { shared.answered[tab.id] = (s, true) }
            let config = TranslationSession.Configuration(source: source, target: target)
            // An equal configuration would not restart the task; invalidating it does.
            if shared.configs[window] == config { shared.configs[window]?.invalidate() }
            else { shared.configs[window] = config }
        }
    }

    /// Another tab's job is waiting for, or running in, the window's one session.
    private static func busy(_ window: ObjectIdentifier, besides tab: Tab) -> Bool {
        if let job = shared.pending[window], job.tab !== tab { return true }
        guard let id = shared.running[window] else { return false }
        return shared.tabs.contains { $0.key != tab.id && $0.value == id }
    }

    /// Runs inside `.translationTask` for `window`. Batches go back to the page as they
    /// come, so a long page fills in from the top rather than all at once at the end. The
    /// session never leaves this function: it is not `Sendable`, so only plain strings
    /// cross to the main actor.
    fileprivate nonisolated static func run(_ session: TranslationSession, window: ObjectIdentifier) async {
        guard let job = await begin(window) else { return }
        let texts = job.texts
        do {
            for start in stride(from: 0, to: texts.count, by: batchSize) {
                try Task.checkCancellation()
                let requests = texts[start..<min(start + batchSize, texts.count)].enumerated().map {
                    TranslationSession.Request(sourceText: $1, clientIdentifier: String(start + $0))
                }
                var out: [String: String] = [:]
                for r in try await session.translations(from: requests) {
                    if let id = r.clientIdentifier { out[id] = r.targetText }
                }
                guard await apply(out, job) else { return }
            }
        } catch {
            await stopped(job, window: window, cancelled: Task.isCancelled)
        }
    }

    /// `forget` drops a job whose document was replaced before it began.
    private static func begin(_ window: ObjectIdentifier) -> Job? {
        guard let job = shared.pending.removeValue(forKey: window), job.tab.existingWeb != nil else { return nil }
        shared.tabs[job.tab.id] = job.id
        shared.offers[job.tab.id] = nil
        shared.running[window] = job.id
        SiteChanges.shared.bump()
        return job
    }

    /// False once a new document committed, Show Original was pressed, or a newer job took
    /// the tab while a batch was out. A provisional load alone (a download, a 204) is not.
    private static func apply(_ batch: [String: String], _ job: Job) async -> Bool {
        guard shared.tabs[job.tab.id] == job.id, let web = job.tab.existingWeb else { return false }
        _ = try? await web.callAsyncJavaScript(applyJS, arguments: ["batch": batch], contentWorld: world)
        return true
    }

    /// A failed job, or one cancelled because another tab in the window asked for the
    /// window's one session: either way the page goes back to its own text, not half done.
    private static func stopped(_ job: Job, window: ObjectIdentifier, cancelled: Bool) {
        guard shared.tabs[job.tab.id] == job.id else { return }
        // An equal configuration restarts by `invalidate()`, which may end this session
        // with an error rather than a cancellation; a newer job waiting or begun says why.
        let cancelled = cancelled || shared.pending[window] != nil || shared.running[window] != job.id
        shared.tabs[job.tab.id] = nil
        // A failure (a dismissed download sheet, a session error) must not refire on every
        // later page of the site.
        if !cancelled { shared.answered[job.tab.id] = nil }
        job.tab.existingWeb?.evaluateJavaScript(restoreJS, in: nil, in: world) { _ in }
        SiteChanges.shared.bump()
        Toasts.show(cancelled ? "Stopped translating \u{201C}\(job.tab.title)\u{201D}" : "Couldn't translate this page")
    }

    // MARK: - The offer

    /// After a page finishes loading: offer once per load when its text is in a language
    /// other than the user's, the pair is supported, and the site is not on the never list
    /// or already answered in this tab — where Translate was the answer, translate instead.
    /// Never in private windows, on internal or blank pages, or on an Easel.
    static func offer(_ tab: Tab) {
        let here = site(of: tab)
        if let a = shared.answered[tab.id], a.site != here { shared.answered[tab.id] = nil }
        if shared.answered[tab.id]?.translate == false { return }
        guard !tab.isPrivate, tab.easelID == nil, !isOn(tab), shared.offers[tab.id] == nil,
              let web = tab.existingWeb, let url = web.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty,
              !neverListed(host, in: neverTranslated(profileID: tab.profileID)) else { return }
        let generation = tab.readingDocumentGeneration
        Task {
            guard let result = try? await web.callAsyncJavaScript(sampleJS, contentWorld: world) as? [String: Any],
                  let sample = result["text"] as? String,
                  let source = offerLanguage(lang: result["lang"] as? String, sample: sample,
                                             target: preferredLanguage()),
                  await LanguageAvailability().status(from: source, to: preferredLanguage()) != .unsupported,
                  tab.readingDocumentGeneration == generation, tab.existingWeb === web, !isOn(tab),
                  !shared.pending.values.contains(where: { $0.tab === tab })
            else { return }
            // Read again: Show Original or Not now may have answered during the awaits.
            switch shared.answered[tab.id]?.translate {
            case false?: return
            case true?:
                // Only where the tab is on screen, so the job runs in that tab's window; a tab
                // in the background gets the offer for when the user comes back.
                if let store = TabStore.all.first(where: { $0.active === tab }) {
                    return toggle(tab, in: store, automatic: true)
                }
            case nil: break
            }
            shared.offers[tab.id] = Offer(host: host, language: name(of: source))
        }
    }

    /// The language worth offering a translation from, or nil: too little text to judge,
    /// or already the user's language. Pure.
    nonisolated static func offerLanguage(lang: String?, sample: String, target: Locale.Language) -> Locale.Language? {
        guard sample.unicodeScalars.filter(CharacterSet.letters.contains).count >= 40,
              let source = sourceLanguage(lang: lang, sample: [sample]),
              !sameLanguage(source, target) else { return nil }
        return source
    }

    enum Answer { case translate, notNow, never }

    static func answer(_ offer: Offer, _ answer: Answer, tab: Tab, in store: TabStore?) {
        guard shared.offers[tab.id] == offer else { return }
        shared.offers[tab.id] = nil
        switch answer {
        case .translate: toggle(tab, in: store)
        case .notNow: shared.answered[tab.id] = (site(offer.host), false)
        case .never:
            setOffers(false, host: offer.host, tab: tab)
            axAnnounce("Vane will not offer to translate \(site(offer.host)).")
        }
    }

    // MARK: - Never translate this site

    private static func neverKey(_ profileID: UUID) -> String {
        ProfileManager.defaultsKey("translateNever", profileID)
    }

    /// Sites, without `www.`; one entry covers its subdomains, as `google.com` in Arc's did.
    static func neverTranslated(profileID: UUID) -> [String] {
        UserDefaults.vane.stringArray(forKey: neverKey(profileID)) ?? []
    }

    nonisolated static func site(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    nonisolated static func neverListed(_ host: String, in list: [String]) -> Bool {
        let h = site(host)
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Off from the offer's Never; back on from Site Controls' "Offer to Translate", which
    /// also clears any parent entry covering the host. Never writes for a private tab.
    static func setOffers(_ on: Bool, host: String, tab: Tab) {
        guard !tab.isPrivate else { return }
        setOffers(on, host: host, profileID: tab.profileID)
    }

    private static func setOffers(_ on: Bool, host: String, profileID: UUID) {
        var list = neverTranslated(profileID: profileID)
        if on { list.removeAll { neverListed(host, in: [$0]) } }
        else if !neverListed(host, in: list) { list.append(site(host)) }
        if list.isEmpty { UserDefaults.vane.removeObject(forKey: neverKey(profileID)) }
        else { UserDefaults.vane.set(list.sorted(), forKey: neverKey(profileID)) }
        SiteChanges.shared.bump()
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
    /// The first ~1,000 characters of the page's visible text, for the offer's detector.
    /// Walks visible text nodes and stops there, rather than laying out the whole page for
    /// `innerText`. Empty for a page that asks not to be translated.
    static let sampleJS = """
    const d = document, h = d.documentElement, b = d.body;
    const optOut = e => e && (e.getAttribute('translate')?.toLowerCase() === 'no' || e.classList.contains('notranslate'));
    if (optOut(h) || optOut(b) || [...d.querySelectorAll('meta[name="google" i]')]
        .some(m => /notranslate/i.test(m.content || ''))) return { lang: '', text: '' };
    const skip = 'script,style,noscript,textarea,code,pre,svg,math,template,[translate="no" i],.notranslate';
    const walker = d.createTreeWalker(b || h, NodeFilter.SHOW_TEXT, { acceptNode(n) {
      const p = n.parentElement;
      if (!p || !/\\p{L}/u.test(n.data) || p.closest(skip)) return NodeFilter.FILTER_REJECT;
      if (p.checkVisibility && !p.checkVisibility()) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }});
    let text = '';
    for (let n; text.length < 1000 && (n = walker.nextNode());) text += n.data.trim() + ' ';
    return { lang: h.lang || '', text: text.slice(0, 1000) };
    """

    /// Also puts the page's text back as it is hidden, so a back-forward-cache return (which
    /// commits, and so is untranslated as far as Vane knows) shows the page as it came.
    static let collectJS = """
    if (!globalThis.__vaneTranslationHide) {
      globalThis.__vaneTranslationHide = true;
      addEventListener('pagehide', () => {
        const t = globalThis.__vaneTranslation;
        if (!t) return;
        t.nodes.forEach((n, i) => { if (n.data === t.done[i]) n.data = t.originals[i]; });
        delete globalThis.__vaneTranslation;
      });
    }
    const prior = globalThis.__vaneTranslation;
    if (prior) prior.nodes.forEach((n, i) => { if (n.data === prior.done[i]) n.data = prior.originals[i]; });
    const skip = 'script,style,noscript,textarea,input,select,option,code,pre,kbd,samp,var,svg,math,template,' +
      '[contenteditable]:not([contenteditable="false"]),[translate="no" i],.notranslate';
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
            ("an offer for a page in another language",
             offerLanguage(lang: "en", sample: String(repeating: "Die Katze sitzt auf der Matte. ", count: 3),
                           target: en)?.languageCode == "de"),
            ("no offer for a page already in the user's language",
             offerLanguage(lang: "de", sample: String(repeating: "The cat sits on the mat all day. ", count: 3),
                           target: en) == nil),
            ("no offer on too little text to judge", offerLanguage(lang: "fr", sample: "Bonjour", target: en) == nil),
            ("a never-listed site covers its subdomains", neverListed("WWW.Google.com", in: ["google.com"])
             && neverListed("mail.google.com", in: ["google.com"]) && !neverListed("notgoogle.com", in: ["google.com"])),
            ("the never list round-trips", neverRoundTrip()),
        ]
    }

    /// Writes under a throwaway profile id and removes the key again.
    private static func neverRoundTrip() -> Bool {
        let profile = UUID()
        defer { UserDefaults.vane.removeObject(forKey: neverKey(profile)) }
        setOffers(false, host: "www.youtube.com", profileID: profile)
        setOffers(false, host: "m.youtube.com", profileID: profile)
        let stored = neverTranslated(profileID: profile)
        setOffers(true, host: "music.youtube.com", profileID: profile)
        return stored == ["youtube.com"] && neverTranslated(profileID: profile).isEmpty
            && UserDefaults.vane.object(forKey: neverKey(profile)) == nil
    }

    /// Not pure: a real tab, real commits. Translated state survives nothing but its own
    /// document, and the page puts its own text back as it is hidden (`pagehide`).
    static func liveCheck(tab: Tab, load: (String) -> Bool) -> [(String, Bool)] {
        final class Box { var done = false; var value: Any? }
        func js(_ source: String, _ world: WKContentWorld, _ args: [String: Any] = [:]) -> Any? {
            let box = Box()
            tab.web.callAsyncJavaScript(source, arguments: args, in: nil, in: world) { box.value = try? $0.get(); box.done = true }
            let deadline = Date().addingTimeInterval(5)
            while !box.done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return box.value
        }
        guard load("<p>Bonjour tout le monde</p>") else { return [("a page loads", false)] }
        _ = js(collectJS, world)
        _ = js(applyJS, world, ["batch": ["0": "Hello everyone"]])
        let text = { js("return document.body.innerText", .page) as? String }
        var out = [("a batch rewrites the text node", text() == "Hello everyone")]
        _ = js("dispatchEvent(new PageTransitionEvent('pagehide', {persisted: true}))", .page)
        out.append(("pagehide puts the original text back", text() == "Bonjour tout le monde"))
        shared.tabs[tab.id] = UUID()
        shared.offers[tab.id] = Offer(host: "example.com", language: "French")
        // The next load's host: Not now there holds through its commit and its load.
        shared.answered[tab.id] = ("translate2.example", false)
        out.append(("a committed navigation forgets the translation and the offer",
                    load("<p>Another page</p>") && !isOn(tab) && shared.offers[tab.id] == nil))
        out.append(("but not the site answered in the tab", shared.answered[tab.id]?.site == "translate2.example"))
        forget(tab: tab, released: true)
        out.append(("release forgets the answered site", shared.answered[tab.id] == nil))
        func sample(_ html: String) -> String? {
            load(html) ? (js(sampleJS, world) as? [String: Any])?["text"] as? String : nil
        }
        let visible = sample("<p>Bonjour</p><p hidden>caché</p>")
        out.append(("the offer samples visible text", visible?.contains("Bonjour") == true && visible?.contains("caché") == false))
        out.append(("a page that opts out is not sampled",
                    sample("<html translate=\"no\"><body><p>Bonjour</p></body></html>") == ""
                    && sample("<meta name=\"google\" content=\"notranslate\"><p>Bonjour</p>") == ""))
        return out
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

/// "Translate this page?" under the address pill, where the password offer goes, and
/// mounted beside it whether or not there is an offer — the card decides for itself.
struct TranslateOffer: View {
    let tab: Tab
    let store: TabStore
    @ObservedObject private var translation = PageTranslation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        let offer = translation.offers[tab.id]
        Group {
            if let offer { card(offer).id(offer.id).transition(reduced ? .identity
                : .opacity.combined(with: .scale(scale: Look.appearScale, anchor: .topTrailing))) }
        }
        .animation(reduced ? nil : Look.appear, value: offer?.id)
    }

    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    private func card(_ offer: PageTranslation.Offer) -> some View {
        let answer = { (a: PageTranslation.Answer) in PageTranslation.answer(offer, a, tab: tab, in: store) }
        let title = "Translate this page?"
        return VStack(alignment: .leading, spacing: Look.cardInset) {
            HStack(spacing: Look.inset) {
                Image(systemName: "translate").font(Look.glyph).foregroundStyle(Look.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Look.heading).foregroundStyle(Look.inkPrimary)
                    Text("From \(offer.language), on this Mac").font(Look.caption).foregroundStyle(Look.inkSecondary)
                }
                Spacer(minLength: 0)
                Button { answer(.notNow) } label: {
                    Image(systemName: "xmark").font(Look.glyph)
                        .frame(width: Look.control, height: Look.control).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(Look.inkTertiary)
                .help("Not now").accessibilityLabel("Not now")
            }
            HStack(spacing: Look.inset) {
                Spacer(minLength: 0)
                Button("Never Translate This Site") { answer(.never) }.buttonStyle(.bordered)
                    .accessibilityLabel("Never translate \(PageTranslation.site(offer.host))")
                Button("Translate") { answer(.translate) }.buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(Look.cardInset)
        .frame(maxWidth: Look.offerWidth, alignment: .leading)
        .background(Look.panelFill, in: .rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { axAnnounce(title) }
    }
}
