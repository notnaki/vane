import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum IssueReportWindow {
    private static var controller: ReportWindowController?
    static var window: NSWindow? { controller?.window }
    static var session: IssueReportSession? { controller?.session }

    static func show(in origin: TabStore? = Windows.current) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let session = IssueReportSession(snapshot: DiagnosticLog.shared.snapshot()) { [weak origin] url in
            if let origin, origin.window?.isVisible == true {
                origin.newTab(url)
                origin.window?.makeKeyAndOrderFront(nil)
                return true
            }
            return NSWorkspace.shared.open(url)
        }
        let made = ReportWindowController(session: session)
        controller = made
        made.onClose = { controller = nil }
        made.showWindow(nil)
        made.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() { controller?.window?.close() }
}

@MainActor private final class ReportWindowController: NSWindowController, NSWindowDelegate {
    let session: IssueReportSession
    var onClose: (() -> Void)?

    init(session: IssueReportSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Report a Problem"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        SecondaryWindowStyle.apply(to: window)
        window.contentMinSize = NSSize(width: 580, height: 560)
        window.contentView = SecondaryWindowStyle.host(IssueReportView(session: session,
            save: { [weak self] in self?.save() }).font(Look.text),
            minimumSize: NSSize(width: 580, height: 560))
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func save() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Save Problem Report"
        panel.nameFieldStringValue = "Vane-problem-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let markdown = "# \(session.draft.title)\n\n" + session.draft.markdown
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                session.message("Report saved. You can share the Markdown file when you’re ready.")
            } catch {
                session.message("Could not save the report: \(error.localizedDescription)", error: true)
            }
        }
    }
}

@MainActor final class IssueReportSession: ObservableObject {
    @Published var draft: IssueReportDraft
    @Published private(set) var status = ""
    @Published private(set) var isError = false
    private let openURL: (URL) -> Bool

    init(snapshot: DiagnosticSnapshot, openURL: @escaping (URL) -> Bool) {
        draft = IssueReportDraft(snapshot: snapshot, environment: IssueReportDraft.currentEnvironment)
        self.openURL = openURL
    }

    func message(_ text: String, error: Bool = false) {
        status = text
        isError = error
    }

    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(draft.markdown, forType: .string) else {
            message("Could not copy the report. Try Save Report instead.", error: true)
            return false
        }
        message("Report copied.")
        return true
    }

    func openGitHub(pasteboard: NSPasteboard = .general) {
        guard draft.canShare else { return }
        let handoff = draft.handoff
        if handoff.requiresPaste, !copy(to: pasteboard) { return }
        guard openURL(handoff.url) else {
            message("Could not open GitHub. Copy or save the report and visit github.com/notnaki/vane/issues.", error: true)
            return
        }
        message(handoff.requiresPaste
            ? "Report copied. Paste it into the GitHub issue with Command-V, then review and submit."
            : "GitHub draft opened. Review it there, then submit when you’re ready.")
    }
}

private struct IssueReportView: View {
    @ObservedObject var session: IssueReportSession
    let save: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @FocusState private var titleFocused: Bool

    var body: some View {
        let handoff = session.draft.handoff
        VStack(alignment: .leading, spacing: Look.sectionGap) {
            SecondaryWindowHeader(title: "Report a Problem",
                subtitle: "Tell us what happened. Review your report before sharing it.",
                icon: "bubble.left")
            ScrollView {
                VStack(alignment: .leading, spacing: Look.sectionGap) {
                    VStack(alignment: .leading, spacing: Look.rowGap) {
                        Text("Summary").font(Look.heading)
                        TextField("A short title for the problem", text: $session.draft.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Problem summary")
                            .focused($titleFocused)
                    }
                    VStack(alignment: .leading, spacing: Look.rowGap) {
                        Text("What happened?").font(Look.heading)
                        Text("Include steps to reproduce, what you expected, and what happened instead.")
                            .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                        TextEditor(text: $session.draft.details)
                            .font(Look.text).scrollContentBackground(.hidden)
                            .padding(Look.rowGap)
                            .frame(height: 110)
                            .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
                            .accessibilityLabel("Problem description and steps to reproduce")
                    }
                    VStack(alignment: .leading, spacing: Look.rowGap) {
                        Toggle("Include recent diagnostic logs", isOn: $session.draft.includeLogs)
                            .toggleStyle(.checkbox)
                        Text("Only Vane events and numeric error codes. No page URLs, titles, content, or private-tab activity.")
                            .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if session.draft.includeLogs {
                            Picker("Time window", selection: $session.draft.period) {
                                ForEach(DiagnosticPeriod.allCases, id: \.rawValue) { period in
                                    Text(period.label).tag(period)
                                }
                            }
                            .fixedSize()
                            Text("\(session.draft.selectedEvents.count) events · Snapshot at \(session.draft.snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                                .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                            Text("Keeps at most 2,000 events from the last 5 minutes in memory. Reopen this window for a fresh snapshot.")
                                .font(Look.caption).foregroundStyle(Look.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick,
                               value: session.draft.includeLogs)
                    VStack(alignment: .leading, spacing: Look.rowGap) {
                        Text("Report preview").font(Look.heading)
                        ScrollView {
                            Text(session.draft.markdown)
                                .font(.system(size: Look.Typography.secondary.size, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Look.cardInset)
                        }
                        .frame(height: 170)
                        .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
                        .accessibilityLabel("Exact report preview")
                    }
                }
                .padding(.trailing, Look.rowGap)
            }
            VStack(alignment: .leading, spacing: Look.rowGap) {
                Text("GitHub issues are public. Remove anything you don’t want to share.")
                    .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                if handoff.requiresPaste {
                    Text("This report is too long for a GitHub link. The button copies the full report so you can paste it into the issue.")
                        .font(Look.footnote).foregroundStyle(Look.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !session.status.isEmpty {
                    Text(session.status).font(Look.footnote)
                        .foregroundStyle(session.isError ? .red : Look.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("issue-report-status")
                }
                HStack {
                    Button("Copy Report") { session.copy() }
                    Button("Save Report…", action: save)
                    Spacer()
                    Button(handoff.requiresPaste ? "Copy & Open GitHub…" : "Open GitHub Issue…") {
                        session.openGitHub()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.draft.canShare)
                }
                .padding(.top, Look.rowGap)
            }
        }
        .padding(Look.cardInset)
        .onAppear { titleFocused = true }
    }
}
