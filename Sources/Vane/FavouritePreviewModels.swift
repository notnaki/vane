import Foundation

/// Website sessions, never the independently authorized Live Folders account.
enum FavouritePreviewService: String, CaseIterable, Identifiable, Sendable {
    case github, gmail, calendar
    var id: String { rawValue }
    var title: String {
        switch self { case .github: "GitHub"; case .gmail: "Gmail"; case .calendar: "Google Calendar" }
    }
    var host: String {
        switch self { case .github: "github.com"; case .gmail: "mail.google.com"; case .calendar: "calendar.google.com" }
    }
    var heading: String {
        switch self { case .github: "Open pull requests"; case .gmail: "Recent inbox messages"; case .calendar: "Upcoming events" }
    }
    static func resolve(_ url: URL) -> Self? {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return allCases.first { $0.host == url.host?.lowercased() }
    }
}

struct FavouritePreviewContext: Hashable, Sendable {
    let profileID: UUID
    let service: FavouritePreviewService
    /// Account slot is part of the routing identity, not proof of who is signed in.
    let route: String
    let authuser: String?

    init?(profileID: UUID, url: URL) {
        guard let service = FavouritePreviewService.resolve(url) else { return nil }
        self.profileID = profileID
        self.service = service
        let prefix = service == .gmail ? "mail" : "calendar"
        let parts = url.pathComponents
        if service != .github, parts.count > 3, parts[1] == prefix, parts[2] == "u",
           parts[3].allSatisfy(\.isNumber), parts[3].count < 4, !parts[3].isEmpty {
            route = "/\(prefix)/u/\(parts[3])/"
        } else { route = service == .github ? "/" : "/\(prefix)/u/0/" }
        authuser = service == .github ? nil : URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "authuser" })?.value
    }

    var siteURL: URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = service.host
        components.path = route
        if let authuser { components.queryItems = [URLQueryItem(name: "authuser", value: authuser)] }
        if service == .gmail { components.fragment = "inbox" }
        return components.url!
    }
    var entryURL: URL {
        if service == .github {
            var components = URLComponents(string: "https://github.com/pulls")!
            components.queryItems = [URLQueryItem(name: "q", value: "is:open is:pr involves:@me sort:updated-desc")]
            return components.url!
        }
        if service == .calendar {
            var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)!
            components.path = route + "r/agenda"
            return components.url!
        }
        return siteURL
    }
    var composeURL: URL? {
        guard service == .gmail else { return nil }
        var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)!
        components.fragment = "inbox?compose=new"
        return components.url
    }
}

struct FavouritePreviewItem: Identifiable, Equatable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let subtitle: String
    let url: URL
    var unread = false
    var status: String?
    var timeLabel: String?
    var startsAt: Date?
    var meetingURL: URL?
}

struct FavouritePreviewSnapshot: Equatable, Sendable {
    let account: String
    let items: [FavouritePreviewItem]
}

enum FavouritePreviewResult: Equatable, Sendable {
    case ready(FavouritePreviewSnapshot), signedOut, unavailable
}

enum FavouritePreviewState: Equatable {
    case loading, ready(FavouritePreviewSnapshot), stale(FavouritePreviewSnapshot), signedOut, unavailable
}

enum FavouritePreviewURL {
    static func https(_ raw: String) -> URL? {
        guard raw.count <= 4096, let url = URL(string: raw), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
    static func item(_ raw: String, service: FavouritePreviewService) -> URL? {
        guard let url = https(raw), url.host == service.host else { return nil }
        switch service {
        case .github:
            let parts = url.pathComponents
            guard parts.count == 5, parts[3] == "pull", Int(parts[4]) != nil else { return nil }
        case .gmail:
            guard url.path.hasPrefix("/mail/"), let fragment = url.fragment,
                  fragment.hasPrefix("inbox/"), fragment.count > 6,
                  !fragment.contains("?"), !fragment.contains("&") else { return nil }
        case .calendar:
            guard url.path.hasPrefix("/calendar/"),
                  url.path.contains("/eventedit/") || URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name == "eid" && $0.value?.isEmpty == false }) == true
            else { return nil }
        }
        return url
    }
    /// Only known web meeting destinations; custom schemes still go through site controls.
    static func meeting(_ raw: String) -> URL? {
        guard let url = https(raw), let host = url.host?.lowercased(),
              host == "meet.google.com" || host == "teams.microsoft.com" || host == "teams.live.com"
                || host == "zoom.us" || host.hasSuffix(".zoom.us") || host.hasSuffix(".webex.com")
        else { return nil }
        return url
    }
}

/// No disk tier. Explicit account identity is required even within the same profile/slot.
struct FavouritePreviewCache {
    struct Hit { let snapshot: FavouritePreviewSnapshot; let stale: Bool }
    private struct Key: Hashable { let context: FavouritePreviewContext; let account: String }
    private struct Entry { let snapshot: FavouritePreviewSnapshot; let at: Date }
    private var entries: [Key: Entry] = [:]
    static let ttl: TimeInterval = 120
    static let lifetime: TimeInterval = 600
    static let capacity = 12

    mutating func store(_ snapshot: FavouritePreviewSnapshot, context: FavouritePreviewContext, now: Date = .now) {
        // Replacing the account in a slot also retires its old data.
        entries = entries.filter { $0.key.context != context || $0.key.account == snapshot.account }
        entries[Key(context: context, account: snapshot.account)] = Entry(snapshot: snapshot, at: now)
        while entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries[oldest] = nil
        }
    }
    func lookup(context: FavouritePreviewContext, account: String, now: Date = .now) -> Hit? {
        guard !account.isEmpty, let entry = entries[Key(context: context, account: account)],
              now.timeIntervalSince(entry.at) < Self.lifetime else { return nil }
        return Hit(snapshot: entry.snapshot, stale: now.timeIntervalSince(entry.at) >= Self.ttl)
    }
    mutating func invalidate(profileID: UUID) { entries = entries.filter { $0.key.context.profileID != profileID } }
    mutating func removeAll() { entries.removeAll() }
}
