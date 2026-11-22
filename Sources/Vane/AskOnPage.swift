import SwiftUI
import WebKit

// MARK: - The conversation

/// Arc's ⌘F → Ask: free-form questions about the page in front of you, answered from its
/// text. One conversation per window, held by the find session; it is cleared when the bar
/// closes or the question is about a different page.
///
/// ponytail: page text comes from `Reader.extract`, the summarizer's extraction. Ceiling: a
/// page Reader reads poorly (a dashboard, a listing) gets a poor answer. Upgrade path is a
/// whole-body fallback when the extraction is thin.
@MainActor final class AskOnPage: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer = ""
        var pending = true
        var failed = false
    }

    @Published var turns: [Turn] = []
    private var page: String?
    private var task: Task<Void, Never>?

    var busy: Bool { turns.last?.pending == true }

    /// What stops a question being asked at all, in the words the panel shows; nil when it
    /// can be asked. Same gates as page summaries: the master switch, the feature's route,
    /// and no cloud connection in a private window.
    static func blocker(isPrivate: Bool) -> String? {
        guard BrowserAI.enabled else { return "Turn on Max to ask questions about pages." }
        if let reason = BrowserAI.unavailableReason(for: .askOnPage) { return reason }
        if isPrivate, BrowserAI.state.connection(for: .askOnPage) != nil {
            return "Cloud AI is never used in private windows. Choose Apple (On Device) for Ask on Page to use it here."
        }
        return nil
    }

    func ask(_ raw: String, in tab: Tab) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, let web = tab.existingWeb else { return }
        let key = tab.id.uuidString + " " + (web.url?.absoluteString ?? "")
        if page != key { turns = []; page = key }
        let history = turns.filter { !$0.failed && !$0.answer.isEmpty }.map { (question: $0.question, answer: $0.answer) }
        turns.append(Turn(question: question))
        let isPrivate = tab.isPrivate
        task = Task { [weak self] in
            var answer = ""
            if let e = await Reader.extract(from: web) {
                let text = (e.title + "\n\n" + Reader.plainText(e.nodes)).trimmingCharacters(in: .whitespacesAndNewlines)
                for await element in BrowserAI.askStream(page: text, question: question, history: history, isPrivate: isPrivate) {
                    guard let self, !Task.isCancelled else { return }
                    answer = element.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.update { $0.answer = answer }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.update { $0.pending = false; $0.failed = answer.isEmpty }
            axAnnounce(answer.isEmpty ? "No answer" : answer)
        }
    }

    private func update(_ change: (inout Turn) -> Void) {
        guard !turns.isEmpty else { return }
        change(&turns[turns.count - 1])
    }

    func reset() {
        task?.cancel(); task = nil
        turns = []; page = nil
    }
}

// MARK: - The panel

/// The find bar's Ask mode: a question field above the conversation. Escape closes the bar
/// exactly as it does in find mode; the magnifying glass goes back to find.
struct AskPanel: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @EnvironmentObject var store: TabStore
    @ObservedObject var session: Find
    @ObservedObject var ask: AskOnPage
    @ObservedObject var tab: Tab
    @AppStorage("aiSettingsRevision", store: .vane) private var revision = 0
    @AppStorage("appleAI", store: .vane) private var enabled = false
    @State private var text = ""
    @State private var ready = false
    /// Keychain-backed, so computed on appear and settings changes rather than per body —
    /// the body redraws on every streamed snapshot.
    @State private var blocker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            HStack(spacing: Look.inset) {
                Image(systemName: "sparkles").font(Look.caption).foregroundStyle(.secondary)
                ZStack {
                    Color.clear
                    if ready {
                        CommandField(text: $text, prompt: ask.turns.isEmpty ? "Ask about this page" : "Ask a follow-up",
                                     selectAll: true, label: "Ask on Page",
                                     hint: "Return asks the question. Escape closes the bar.",
                                     font: Look.Typography.secondary.native,
                                     focusRequest: session.focusRequest, onKey: key)
                    }
                }
                .frame(width: Look.findFieldWidth + Look.findCountWidth, height: Look.control)
                Button { submit() } label: { Image(systemName: "arrow.up") }
                    .help("Ask").accessibilityLabel("Ask")
                    .disabled(blocker != nil || ask.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { session.asking = false } label: { Image(systemName: "magnifyingglass") }
                    .help("Find on Page").accessibilityLabel("Find on Page")
                Button { close() } label: { Image(systemName: "xmark") }
                    .help("Close").accessibilityLabel("Close Ask on Page")
            }
            if let blocker {
                VStack(alignment: .leading, spacing: Look.inset) {
                    Text(blocker).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Max Settings") { SettingsWindow.show(tab: "max") }
                        .buttonStyle(.link)
                }
                .transition(.opacity)
            } else if !ask.turns.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(ask.turns) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.question).fontWeight(.semibold)
                                    if turn.failed {
                                        Text("No answer. The page may have too little text, or AI is busy. Try again.")
                                            .foregroundStyle(.secondary)
                                    } else if turn.answer.isEmpty {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text(turn.answer).textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(turn.id)
                                .transition(.opacity)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: ask.turns) { proxy.scrollTo(ask.turns.last?.id, anchor: .bottom) }
                }
                .transition(.opacity)
            }
        }
        .frame(width: Look.findFieldWidth + Look.findCountWidth + 3 * Look.control + 4 * Look.inset + 16)
        .animation(Motion.reduced ? nil : Look.quick, value: ask.turns)
        .animation(Motion.reduced ? nil : Look.quick, value: blocker)
        .buttonStyle(CompactControlStyle(bar: true)).font(Look.caption).foregroundStyle(Look.barText)
        .padding(.horizontal, Look.rowTrailingInset).padding(.vertical, Look.rowPadding)
        .background(chromeTheme.barFill, in: .rect(cornerRadius: Look.cardRadius))
        .background(Look.barMaterial, in: .rect(cornerRadius: Look.cardRadius))
        .hairline(radius: Look.cardRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .environment(\.colorScheme, .dark)
        .onAppear {
            blocker = AskOnPage.blocker(isPrivate: tab.isPrivate)
            // Arrived from the find bar's Ask button with a query typed: that is the question.
            text = session.askDraft
            session.askDraft = ""
            ready = true
            if !text.isEmpty, ask.turns.isEmpty { submit() }
        }
        .onChange(of: revision) { blocker = AskOnPage.blocker(isPrivate: tab.isPrivate) }
        .onChange(of: enabled) { blocker = AskOnPage.blocker(isPrivate: tab.isPrivate) }
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask on Page")
        .accessibilitySortPriority(1)
    }

    private func key(_ k: CommandField.Key) -> Bool {
        switch k {
        case .enter, .shiftEnter, .commandEnter: submit()
        case .escape: close()
        case .up, .down, .tab, .forget, .backspace, .dismissCompletion: return false
        }
        return true
    }

    private func submit() {
        guard blocker == nil, !ask.busy else { return }
        let question = text
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        ask.ask(question, in: tab)
    }

    private func close() {
        store.findOpen = false
        store.focusPage()
    }
}

extension TabStore {
    /// The command bar's "Ask on Page": the find bar, opened straight into Ask mode.
    func openAsk() {
        guard active?.easelID == nil else { return }
        let session = Find.session(for: self)
        session.askDraft = ""
        session.asking = true
        findOpen = true
        session.requestFocus()
    }
}
