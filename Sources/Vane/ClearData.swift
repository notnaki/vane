import AppKit
import SwiftUI
import WebKit

// MARK: - What "Clear Browsing Data" means

/// Chromium's Clear Browsing Data dialog, as much of it as Vane has data for: what to clear,
/// how far back, and the one place that knows which WebKit data types each checkbox stands
/// for. Everything here except `clear` itself is pure, so the mapping can be proved without
/// a data store — and the mapping is the part that silently does nothing when it is wrong.
@MainActor enum BrowsingData {

    /// How far back. Arc offers Chromium's five.
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case hour, day, week, month, everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hour:       "Last hour"
            case .day:        "Last 24 hours"
            case .week:       "Last 7 days"
            case .month:      "Last 4 weeks"
            case .everything: "All time"
            }
        }

        /// Nil for "all time", which is not "a very long window" — WebKit is handed
        /// `.distantPast`, and history is a `DELETE` with no `WHERE`.
        var seconds: TimeInterval? {
            switch self {
            case .hour:       3600
            case .day:        86_400
            case .week:       604_800
            case .month:      2_419_200
            case .everything: nil
            }
        }

        /// The cut-off this range means, given when "now" is.
        func since(_ now: Date = .now) -> Date {
            seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast
        }
    }

    /// The three checkboxes. History is on by default because it is the one everybody means.
    struct Options: Equatable, Sendable {
        var history = true
        var cookies = false
        var cache = false
        var range: Range = .everything

        /// Nothing ticked clears nothing; the button says so by being disabled.
        var isEmpty: Bool { !history && !cookies && !cache }
    }

    /// The WebKit data types each checkbox stands for.
    ///
    /// "Cookies and site data" is not just cookies: a site that has been logged out of by
    /// deleting its cookie and left holding its localStorage token has not been logged out
    /// of. Caches are separate because clearing them costs a slow reload and nothing else.
    static func dataTypes(cookies: Bool, cache: Bool) -> Set<String> {
        var types: Set<String> = []
        if cookies {
            types.formUnion([
                WKWebsiteDataTypeCookies,
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeSessionStorage,
                WKWebsiteDataTypeIndexedDBDatabases,
                WKWebsiteDataTypeWebSQLDatabases,
                WKWebsiteDataTypeServiceWorkerRegistrations,
            ])
        }
        if cache {
            types.formUnion([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
            ])
        }
        return types
    }

    /// What the button is about to do, in one sentence, so the confirmation is not a guess.
    static func summary(_ options: Options) -> String {
        var parts: [String] = []
        if options.history { parts.append("browsing history") }
        if options.cookies { parts.append("cookies and site data") }
        if options.cache   { parts.append("cached files") }
        guard !parts.isEmpty else { return "Nothing is selected." }
        let list: String
        switch parts.count {
        case 1:  list = parts[0]
        case 2:  list = parts.joined(separator: " and ")
        default: list = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        let when = options.range == .everything
            ? "from the beginning of time"
            : "from the \(options.range.title.lowercased())"
        return "Clears \(list) \(when). Bookmarks and saved passwords are not affected."
    }

    /// Do it. History is Vane's own database; cookies, storage and caches belong to the
    /// profile's `WKWebsiteDataStore`, which is why this cannot be one call.
    static func clear(_ options: Options, profileID: UUID, now: Date = .now) {
        let since = options.range.since(now)
        if options.history {
            Store.store(for: profileID).clearHistory(since: options.range == .everything ? nil : since)
        }
        let types = dataTypes(cookies: options.cookies, cache: options.cache)
        guard !types.isEmpty else { return }
        ProfileManager.dataStore(for: profileID)
            .removeData(ofTypes: types, modifiedSince: since) { }
    }

    // MARK: Offline check

    static func check() -> [(String, Bool)] {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let cookieTypes = dataTypes(cookies: true, cache: false)
        let cacheTypes = dataTypes(cookies: false, cache: true)
        var everything = Options()
        everything.cookies = true
        everything.cache = true
        var justCookies = Options(history: false, cookies: true, cache: false, range: .hour)
        return [
            ("history is what a fresh dialog offers to clear",
             Options().history && !Options().cookies && !Options().cache),
            ("…for all time, until the user picks a window", Options().range == .everything),
            ("nothing ticked is nothing to do", Options(history: false).isEmpty),

            ("clearing nothing asks WebKit for nothing",
             dataTypes(cookies: false, cache: false).isEmpty),
            ("cookies means cookies", cookieTypes.contains(WKWebsiteDataTypeCookies)),
            ("…and the site storage a login also lives in",
             cookieTypes.contains(WKWebsiteDataTypeLocalStorage)
                && cookieTypes.contains(WKWebsiteDataTypeSessionStorage)
                && cookieTypes.contains(WKWebsiteDataTypeIndexedDBDatabases)),
            ("…and the service workers that would put it back",
             cookieTypes.contains(WKWebsiteDataTypeServiceWorkerRegistrations)),
            ("…but never the caches, which are the other checkbox",
             !cookieTypes.contains(WKWebsiteDataTypeDiskCache)),
            ("cache means every cache WebKit keeps",
             cacheTypes.contains(WKWebsiteDataTypeDiskCache)
                && cacheTypes.contains(WKWebsiteDataTypeMemoryCache)
                && cacheTypes.contains(WKWebsiteDataTypeFetchCache)),
            ("…and never the cookies, which are the other checkbox",
             !cacheTypes.contains(WKWebsiteDataTypeCookies)),
            ("both checkboxes ask for both sets",
             dataTypes(cookies: true, cache: true) == cookieTypes.union(cacheTypes)),

            ("an hour back is an hour back",
             Range.hour.since(t0) == t0.addingTimeInterval(-3600)),
            ("a day back is a day back",
             Range.day.since(t0) == t0.addingTimeInterval(-86_400)),
            ("four weeks back is four weeks back",
             Range.month.since(t0) == t0.addingTimeInterval(-2_419_200)),
            ("all time is the distant past, not a long window",
             Range.everything.since(t0) == .distantPast),
            ("every range names itself", Range.allCases.allSatisfy { !$0.title.isEmpty }),

            ("one box selected reads as one thing",
             summary(Options()).hasPrefix("Clears browsing history from the beginning of time")),
            ("two boxes are joined with an and",
             summary(justCookies).hasPrefix("Clears cookies and site data from the last hour")),
            ("three boxes are a list with one and",
             summary(everything).hasPrefix(
                "Clears browsing history, cookies and site data and cached files")),
            ("the summary says what is safe, every time",
             summary(everything).hasSuffix("Bookmarks and saved passwords are not affected.")),
            ("nothing selected says so rather than promising to clear nothing",
             summary(Options(history: false)) == "Nothing is selected."),
            ("a time window is named in the sentence",
             { justCookies.range = .week
               return summary(justCookies).contains("from the last 7 days") }()),
        ]
    }
}

// MARK: - The dialog

/// Chromium's dialog, in the shape the rest of this window is built from: a card of rows,
/// a footnote that says exactly what the buttons will do, and no surprises.
struct ClearDataSheet: View {
    let profileID: UUID
    let profileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var options = BrowsingData.Options()

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            Text("Clear Browsing Data").font(Look.heading)
            Text("From “\(profileName)”. Other profiles are not touched.")
                .font(Look.footnote).foregroundStyle(Look.inkQuiet)

            SettingsCard {
                SettingsRow("Time range") {
                    Picker("", selection: $options.range) {
                        ForEach(BrowsingData.Range.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("Browsing history") {
                    Toggle("", isOn: $options.history).labelsHidden()
                }
                SettingsRow("Cookies and site data") {
                    Toggle("", isOn: $options.cookies).labelsHidden()
                }
                SettingsRow("Cached files and images") {
                    Toggle("", isOn: $options.cache).labelsHidden()
                }
                Footnote(BrowsingData.summary(options))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clear Data") {
                    BrowsingData.clear(options, profileID: profileID)
                    rebuild()          // the History menu lists what was just deleted
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(options.isEmpty)
            }
        }
        .padding(Look.paneMargin)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clear Browsing Data")
    }
}
