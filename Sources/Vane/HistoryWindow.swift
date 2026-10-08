import AppKit
import SwiftUI

/// ⌘Y — Arc's View History, which in Arc is a Chromium history page. Vane's history lives
/// in its own SQLite table, so this is a window over that table: search, grouped by day,
/// click a line to open it again, ⌫ to forget one, Clear History… for all of it.
///
/// ponytail: one NSWindow made once and reused, exactly as `SettingsWindow` does it — the
/// app has no window-controller hierarchy and the frame autosave is what "remembers where
/// it was" costs. Rows come off the store on demand rather than being held in an
/// ObservableObject: history changes while you browse, and a window you have open is
/// refreshed by cancellable searches and committed history-change notifications.
@MainActor enum HistoryWindow {
    private static var window: NSWindow?

    static func showWriteFailure(_ store: Store) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update browsing history"
        alert.informativeText = (store.lastHistoryError ?? "The history database could not be written.")
            + "\n\nYour history has not been changed. Try again after resolving the storage problem."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func show(profileID: UUID = Windows.current?.profileID ?? ProfileManager.activeProfileID) {
        if let w = window {
            w.contentView = NSHostingView(rootView: HistoryView(profileID: profileID)
                .font(Look.text))
            w.title = profileID == Profile.incognito.id ? "History — Incognito" : "History"
            w.appearance = profileID == Profile.incognito.id ? NSAppearance(named: .darkAqua) : nil
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = profileID == Profile.incognito.id ? "History — Incognito" : "History"
        w.appearance = profileID == Profile.incognito.id ? NSAppearance(named: .darkAqua) : nil
        w.minSize = NSSize(width: 520, height: 360)
        w.isReleasedWhenClosed = false        // closing must not free the instance we keep
        window = w
        w.contentView = NSHostingView(rootView: HistoryView(profileID: profileID)
            .font(Look.text))
        // Position first, autosave second: setFrameUsingName reports whether there was one.
        if !w.setFrameUsingName("VaneHistory") { w.center() }
        w.setFrameAutosaveName("VaneHistory")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - The window's contents

private struct HistoryView: View {
    let profileID: UUID
    @State private var selectedProfileID: UUID
    @State private var period = HistoryPeriod.all
    @State private var revision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @ObservedObject private var profiles = ProfileManager.shared
    private var store: Store { Store.store(for: selectedProfileID) }

    init(profileID: UUID) {
        self.profileID = profileID
        _selectedProfileID = State(initialValue: profileID)
    }

    private struct Request: Equatable {
        let profileID: UUID
        let query: String
        let period: HistoryPeriod
        let revision: Int
    }
    private var request: Request {
        Request(profileID: selectedProfileID, query: query, period: period, revision: revision)
    }
    @State private var query = ""
    @State private var visits: [Visit] = []
    @State private var groups: [(title: String, visits: [Visit])] = []
    @State private var searching = true
    @State private var selection: Visit.ID?
    @State private var hovered: Visit.ID?
    /// Which half of the window the keyboard is talking to: typing goes to the field, ⌫
    /// to the list. Clicking a row moves it, so a row you just clicked can be forgotten
    /// with the next keystroke.
    @FocusState private var focus: Field?

    private enum Field { case search, list }

    /// As many lines as anybody scrolls before they search instead. The search itself is a
    /// query, not a filter over these, so the cap never hides an older page from a search.
    private static let limit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            header
            filters
            // Keep the scroll/focus host mounted through debounce, empty results and
            // completion. A keystroke must not replace the entire navigation surface.
            list.overlay(alignment: .topLeading) {
                if visits.isEmpty { empty }
            }
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.paneMargin)
        .padding(.bottom, Look.paneMargin)
        .background(.windowBackground)
        .onAppear { focus = .search }
        .onChange(of: query) { clearResults() }
        .onChange(of: selectedProfileID) { clearResults() }
        .onChange(of: period) { clearResults() }
        .task(id: request) {
            guard profileID != Profile.incognito.id else { clearResults(); searching = false; return }
            let asked = request
            if !query.isEmpty {
                try? await Task.sleep(for: LocalSuggestionReader.debounce)
            }
            guard !Task.isCancelled else { return }
            let results = await store.historyAsync(matching: asked.query, limit: Self.limit,
                                                   interval: asked.period.interval())
            guard !Task.isCancelled, asked == request else { return }
            visits = results
            groups = asked.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? HistoryWindow.grouped(results) : (results.isEmpty ? [] : [("Results", results)])
            searching = false
            if let selected = selection, !results.contains(where: { $0.id == selected }) {
                selection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Store.historyChanged)) { note in
            if note.object as? Store === store { reload() }
        }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: period)
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: selectedProfileID)
        .vaneMotionPolicy()
    }

    private var filters: some View {
        HStack(spacing: Look.inset) {
            if profileID != Profile.incognito.id {
                Picker("Profile", selection: $selectedProfileID) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .fixedSize()
                .accessibilityHint("Searches only the selected profile's saved history.")
                Picker("Date", selection: $period) {
                    ForEach(HistoryPeriod.allCases, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                }
                .fixedSize()
            }
            Spacer()
            Text("\(visits.count)\(visits.count == Self.limit ? "+" : "") visits")
                .font(Look.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Showing \(visits.count) visits")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset - 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .font(Look.text)
                    .focused($focus, equals: .search)
            }
            .padding(.horizontal, Look.inset)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
            .accessibilityLabel("Search History")
            .accessibilityHint("Matches titles and addresses, including partial letters in order.")

            Button("Clear History…") {
                guard confirm("Clear all browsing history?", "Clear",
                              "Bookmarks and saved passwords are not affected.") else { return }
                guard store.clearHistory() else { HistoryWindow.showWriteFailure(store); return }
                reload()
                axAnnounce("History cleared.")
            }
            .buttonStyle(.plain)
            .font(Look.text)
            .padding(.horizontal, Look.inset + 2)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
        }
    }

    private var empty: some View {
        Text(searching ? "Searching history…" : query.isEmpty
             ? "Nothing here yet — pages you visit are listed by the day you saw them."
             : "No page matches \u{201C}\(query)\u{201D}")
            .font(Look.text).foregroundStyle(.secondary)
            .padding(.horizontal, Look.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Look.inset * 1.5) {
                    ForEach(groups, id: \.title) { group in
                        SettingsSection(group.title) {
                            // SettingsCard's variadic VStack eagerly builds every row
                            // of a day. The common 500-result group must stay lazy too.
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(group.visits) { visit in
                                    row(visit).id(visit.id)
                                    if visit.id != group.visits.last?.id {
                                        Hairline().padding(.horizontal, Look.cardInset)
                                    }
                                }
                            }
                            .background(Look.cardFill, in: .rect(cornerRadius: Look.cardRadius))
                            .hairline(radius: Look.cardRadius, Look.cardStroke)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onDeleteCommand { deleteSelected() }
            .onMoveCommand { direction in
                if direction == .up { moveSelection(-1) }
                if direction == .down { moveSelection(1) }
            }
            .onKeyPress(.return) {
                guard let visit = visits.first(where: { $0.id == selection }) else { return .ignored }
                open(visit)
                return .handled
            }
            .onChange(of: selection) {
                guard let selection else { return }
                withAnimation(reduceMotion || batterySaver.isActive ? nil : Look.quick) {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
            .accessibilityLabel("History")
        }
    }

    private func row(_ visit: Visit) -> some View {
        let isSelected = selection == visit.id
        return HStack(spacing: Look.inset) {
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? HistoryWindow.time(visit.at)
                 : DateText.string(visit.at, template: "yMdjmm", calendar: .current))
                .font(Look.caption).foregroundStyle(Look.inkQuiet)
                .frame(width: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 56 : 125,
                       alignment: .leading)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.display).font(Look.text).foregroundStyle(Look.inkPrimary).lineLimit(1)
                Text(visit.url).font(Look.caption).foregroundStyle(Look.inkQuiet).lineLimit(1)
            }
            Spacer(minLength: Look.inset)
            // The forget button only shows under the pointer, the way Arc's restore icon
            // does — every row carrying an ✕ makes a history list look like a to-do list.
            if hovered == visit.id {
                Button { delete(visit) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .font(Look.caption)
                    .foregroundStyle(.secondary)
                    .help("Forget this visit")
                    .accessibilityLabel("Forget \(visit.display)")
            }
        }
        .padding(.horizontal, Look.cardInset)
        .frame(minHeight: Look.linkRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Look.selected : (hovered == visit.id ? Look.hovered : .clear))
        .contentShape(.rect)
        .onHover { hovered = $0 ? visit.id : (hovered == visit.id ? nil : hovered) }
        .onTapGesture { open(visit) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visit.display)
        .accessibilityValue("\(visit.url), \(DateText.string(visit.at, template: "yMdjmm", calendar: .current))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this page in a new tab.")
        .accessibilityAction { open(visit) }
    }

    // MARK: Doing things

    private func reload() { revision += 1 }

    private func clearResults() {
        visits = []; groups = []; selection = nil; hovered = nil; searching = true
    }

    /// Opens the page in a new tab and *stays* — the browser window is not pulled to the
    /// front. A history window you are working through is a list you are still reading, and
    /// keeping it key is also what leaves ⌫ pointed at the row you just clicked.
    private func open(_ visit: Visit) {
        selection = visit.id
        focus = .list
        guard let url = URL(string: visit.url) else { return }
        BookmarkManager.browserWindow(for: selectedProfileID)?.newTab(url)
        axAnnounce("Opened \(visit.display) in a new tab.")
    }

    private func delete(_ visit: Visit) {
        guard store.deleteVisit(visit.id) else { HistoryWindow.showWriteFailure(store); return }
        if selection == visit.id { selection = nil }
        reload()
        axAnnounce("Forgot \(visit.display).")
    }

    private func moveSelection(_ delta: Int) {
        guard !visits.isEmpty else { return }
        let current = visits.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : visits.count)
        let next = max(0, min(visits.count - 1, current + delta))
        selection = visits[next].id
        axAnnounce(visits[next].display)
    }

    private func deleteSelected() {
        guard let id = selection, let visit = visits.first(where: { $0.id == id }) else { return }
        delete(visit)
    }
}

// MARK: - Writing a date

/// Formatted dates, without building a `DateFormatter` per row.
///
/// A `DateFormatter` costs about as much to make as it costs to format a hundred dates with,
/// and the Library regroups on every keystroke over as many as `Archive.limit` entries, each
/// of which asks for a day header and a time. One formatter per (template, locale, time
/// zone), kept for the life of the process.
///
/// ponytail: a lock around the whole call rather than an actor or a `@MainActor` cache.
/// `DateFormatter` is not safe to *use* from two threads either, so handing one out would
/// only move the problem; and the rules that call this are `nonisolated` so that
/// `selfcheck --pure` can drive them without a main actor to hop to.
enum DateText {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, template: String, calendar: Calendar) -> String {
        let key = "\(template)\u{1}\(calendar.locale?.identifier ?? "")\u{1}\(calendar.timeZone.identifier)"
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate(template)
            cache[key] = formatter
        }
        return formatter.string(from: date)
    }
}

// MARK: - The rules, as pure functions

extension HistoryWindow {
    /// Visits under the day they happened, newest day first, in one pass. Sorted here
    /// rather than trusted from the caller so a day can never appear twice.
    nonisolated static func grouped(_ visits: [Visit], now: Date = .now,
                                    calendar: Calendar = .current) -> [(title: String, visits: [Visit])] {
        var out: [(title: String, visits: [Visit])] = []
        var day: Date?
        for visit in visits.sorted(by: { $0.at > $1.at }) {
            let start = calendar.startOfDay(for: visit.at)
            if start != day {
                out.append((dayTitle(start, now: now, calendar: calendar), []))
                day = start
            }
            out[out.count - 1].visits.append(visit)
        }
        return out
    }

    /// What a day's header reads. Today and Yesterday by name, everything else by date —
    /// with the year only when it is not this one, which is how a date is written when it
    /// is being read rather than filed.
    nonisolated static func dayTitle(_ date: Date, now: Date = .now,
                                     calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return DateText.string(date, template: sameYear ? "EEEEdMMMM" : "EEEEdMMMMy",
                               calendar: calendar)
    }

    /// The time column: the clock, in whatever shape the user's locale writes it.
    nonisolated static func time(_ date: Date, calendar: Calendar = .current) -> String {
        DateText.string(date, template: "jmm", calendar: calendar)
    }
}

// MARK: - check

extension HistoryWindow {
    /// Pure: the grouping and the headers, on a fixed calendar so the assertions do not
    /// move with the machine's time zone.
    nonisolated static func check() -> [(String, Bool)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_700_000_000)         // 14 Nov 2023, 22:13 UTC
        func visit(_ id: Int64, _ offset: TimeInterval, _ title: String = "Page") -> Visit {
            Visit(id: id, url: "https://example.com/\(id)", title: title,
                  at: now.addingTimeInterval(offset))
        }
        let today = visit(1, -3600)
        let earlierToday = visit(2, -7200)
        let yesterday = visit(3, -26 * 3600)
        let lastWeek = visit(4, -8 * 86_400)
        let groups = grouped([today, earlierToday, yesterday, lastWeek], now: now, calendar: calendar)

        return [
            ("no visits group into nothing", grouped([], now: now, calendar: calendar).isEmpty),
            ("one day per group, newest first",
             groups.map(\.title) == ["Today", "Yesterday", dayTitle(lastWeek.at, now: now, calendar: calendar)]),
            ("today's visits share one group", groups.first?.visits.count == 2),
            ("…newest first inside it", groups.first?.visits.map(\.id) == [1, 2]),
            ("every visit lands in exactly one group",
             groups.flatMap(\.visits).count == 4
                && Set(groups.flatMap(\.visits).map(\.id)).count == 4),
            ("an out-of-order list still makes one group per day",
             grouped([lastWeek, today, yesterday, earlierToday], now: now, calendar: calendar)
                .map(\.title) == groups.map(\.title)),
            ("today is named, not dated",
             dayTitle(now, now: now, calendar: calendar) == "Today"),
            ("so is yesterday",
             dayTitle(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday"),
            ("midnight yesterday is still Yesterday, not two days ago",
             dayTitle(calendar.startOfDay(for: now.addingTimeInterval(-86_400)),
                      now: now, calendar: calendar) == "Yesterday"),
            ("an older day is dated and names its weekday",
             dayTitle(lastWeek.at, now: now, calendar: calendar).contains("November")
                && dayTitle(lastWeek.at, now: now, calendar: calendar).contains("Monday")),
            ("a day in another year carries the year",
             dayTitle(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar)
                .contains("2022")),
            ("…and this year's days do not",
             !dayTitle(lastWeek.at, now: now, calendar: calendar).contains("2023")),
            ("a visit with no title falls back to its url",
             visit(9, 0, "").display == "https://example.com/9"),
        ]
    }
}

/// Calendar ranges use inclusive starts and exclusive ends, including across DST.
/// There is deliberately no Space filter: visits have no stored Space association.
enum HistoryPeriod: String, CaseIterable, Sendable {
    case all, today, yesterday, week, month
    var title: String {
        switch self {
        case .all: "All time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        guard self != .all else { return nil }
        let today = calendar.startOfDay(for: now)
        let offset = self == .yesterday ? -1 : (self == .week ? -6 : (self == .month ? -29 : 0))
        guard let start = calendar.date(byAdding: .day, value: offset, to: today),
              let end = calendar.date(byAdding: .day, value: self == .yesterday ? 0 : 1, to: today)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}
