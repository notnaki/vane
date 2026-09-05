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
/// refreshed by typing in it or reopening it, which is what a history page does anyway.
@MainActor enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "History"
        w.minSize = NSSize(width: 520, height: 360)
        w.isReleasedWhenClosed = false        // closing must not free the instance we keep
        window = w
        w.contentView = NSHostingView(rootView: HistoryView())
        // Position first, autosave second: setFrameUsingName reports whether there was one.
        if !w.setFrameUsingName("VaneHistory") { w.center() }
        w.setFrameAutosaveName("VaneHistory")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - The window's contents

private struct HistoryView: View {
    @State private var query = ""
    @State private var visits: [Visit] = []
    @State private var selection: Visit.ID?
    @State private var hovered: Visit.ID?

    /// As many lines as anybody scrolls before they search instead. The search itself is a
    /// query, not a filter over these, so the cap never hides an older page from a search.
    private static let limit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            header
            if groups.isEmpty {
                empty
            } else {
                list
            }
        }
        .padding(.top, Look.inset * 2)
        .padding(.horizontal, Look.paneMargin)
        .padding(.bottom, Look.paneMargin)
        .background(.windowBackground)
        .onAppear { reload() }
        .onChange(of: query) { reload() }
    }

    private var groups: [(title: String, visits: [Visit])] {
        HistoryWindow.grouped(visits)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Look.inset) {
            HStack(spacing: Look.inset - 2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .font(Look.text)
            }
            .padding(.horizontal, Look.inset)
            .frame(height: Look.control)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.chipRadius))
            .accessibilityLabel("Search History")
            .accessibilityHint("Matches the title or the address of a page you have visited.")

            Button("Clear History…") {
                guard confirm("Clear all browsing history?", "Clear",
                              "Bookmarks and saved passwords are not affected.") else { return }
                Store.shared.clearHistory()
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
        Text(query.isEmpty
             ? "Nothing here yet — pages you visit are listed by the day you saw them."
             : "No page matches \u{201C}\(query)\u{201D}")
            .font(Look.text).foregroundStyle(.secondary)
            .padding(.horizontal, Look.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Look.inset * 1.5) {
                ForEach(groups, id: \.title) { group in
                    SettingsSection(group.title) {
                        SettingsCard {
                            ForEach(group.visits) { row($0) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        // The list itself takes the key focus, so ⌫ has somewhere to land after a click.
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { deleteSelected() }
        .accessibilityLabel("History")
    }

    private func row(_ visit: Visit) -> some View {
        let isSelected = selection == visit.id
        return HStack(spacing: Look.inset) {
            Text(HistoryWindow.time(visit.at))
                .font(Look.caption).foregroundStyle(Look.inkQuiet)
                .frame(width: 56, alignment: .leading)
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
        .accessibilityValue(visit.url)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this page in a new tab.")
        .accessibilityAction { open(visit) }
    }

    // MARK: Doing things

    private func reload() {
        visits = Store.shared.history(matching: query, limit: Self.limit)
        if let id = selection, !visits.contains(where: { $0.id == id }) { selection = nil }
    }

    private func open(_ visit: Visit) {
        selection = visit.id
        guard let url = URL(string: visit.url) else { return }
        let store = Windows.current ?? Windows.open()
        store.newTab(url)
        store.window?.makeKeyAndOrderFront(nil)
    }

    private func delete(_ visit: Visit) {
        Store.shared.deleteVisit(visit.id)
        if selection == visit.id { selection = nil }
        reload()
        axAnnounce("Forgot \(visit.display).")
    }

    private func deleteSelected() {
        guard let id = selection, let visit = visits.first(where: { $0.id == id }) else { return }
        delete(visit)
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
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEdMMMM" : "EEEEdMMMMy")
        return formatter.string(from: date)
    }

    /// The time column: the clock, in whatever shape the user's locale writes it.
    nonisolated static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
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
