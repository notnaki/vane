import AppKit
import SwiftUI

/// Read-only discovery and an explicit commit of the selected, reviewed source.
/// No source passwords are opened, no Keychain access occurs, and nothing is written
/// until confirm(). Known paths replace folder pickers; macOS privacy still applies.
@MainActor final class OnboardingImport: ObservableObject {
    enum Phase: Equatable { case idle, scanning, review, importing, complete, failed }
    struct ReadIssue: Identifiable {
        let browser: String
        let kind: BrowserImport.Failure.Kind
        struct Detail { let profile: String; let message: String }
        var details: [Detail]
        var profiles: [String] { details.map(\.profile) }
        var id: String { browser + String(describing: kind) }
        var guidance: String {
            switch kind {
            case .accessDenied: "macOS blocked access to some browser data."
            case .busy: "Close \(browser) and check again to include its history and bookmarks."
            case .unavailable: "Some data couldn’t be read. Available items can still be imported."
            }
        }
    }
    enum Section: String, CaseIterable, Identifiable {
        case workspace = "Spaces & tabs", bookmarks = "Bookmarks", history = "History", passwords = "Passwords", cookies = "Cookies"
        var id: Self { self }
    }
    struct Candidate: Identifiable, Sendable {
        enum Payload: Sendable {
            case arc(ArcImport.Scan)
            case browser(BrowserImport.Source)
        }
        let id: String
        let browser: String
        let profile: String
        let spaces: Int
        let tabs: Int
        let bookmarks: Int
        let history: Int
        let passwords: Int
        let cookies: Int
        let payload: Payload
        var sections: [Section] {
            Section.allCases.filter { section in
                switch section {
                case .workspace: spaces > 0 || tabs > 0
                case .bookmarks: bookmarks > 0
                case .history: history > 0
                case .passwords: passwords > 0
                case .cookies: cookies > 0
                }
            }
        }
        func countLabel(_ section: Section) -> String {
            switch section {
            case .workspace: "\(spaces) Spaces · \(tabs) tabs"
            case .bookmarks: bookmarks.formatted()
            case .history: history.formatted()
            case .passwords: passwords.formatted()
            case .cookies: cookies.formatted()
            }
        }
        /// Produce the exact accepted snapshot, with excluded data removed before any
        /// import worker, credential decryption, or destination write can see it.
        func payload(including sections: Set<Section>) -> Payload {
            func library(_ source: BrowserImport.Source) -> BrowserImport.Source {
                .init(visits: sections.contains(.history) ? source.visits : [],
                      bookmarks: sections.contains(.bookmarks) ? source.bookmarks : [])
            }
            switch payload {
            case .browser(let source): return .browser(library(source))
            case .arc(let scan):
                let sidebar = sections.contains(.workspace) ? scan.sidebar : ArcSidebar()
                var accepted = ArcImport.Scan(root: scan.root, sidebar: sidebar, profiles: scan.profiles,
                                              directories: scan.directories)
                accepted.reviewedLibrary = (scan.reviewedLibrary ?? [:]).mapValues(library)
                accepted.vaults = scan.vaults.mapValues { vault in
                    var selected = vault
                    if !sections.contains(.passwords) { selected.logins = [] }
                    if !sections.contains(.cookies) { selected.cookies = [] }
                    if !sections.contains(.passwords) && !sections.contains(.cookies) { selected.unreadable = 0 }
                    return selected
                }
                if sections.contains(.workspace) {
                    accepted.routing = scan.routing
                    accepted.routingUnavailable = scan.routingUnavailable
                } else {
                    // Do not create profiles whose only data was an excluded sidebar.
                    accepted.directories.removeAll { directory in
                        let vault = accepted.vaults[directory]
                        let source = accepted.reviewedLibrary?[directory]
                        return (vault?.logins.isEmpty ?? true) && (vault?.cookies.isEmpty ?? true)
                            && (source?.visits.isEmpty ?? true) && (source?.bookmarks.isEmpty ?? true)
                    }
                }
                return .arc(accepted)
            }
        }
        var summary: String {
            [(spaces, "Space", "Spaces"), (tabs, "tab", "tabs"),
             (bookmarks, "bookmark", "bookmarks"), (history, "history entry", "history entries"),
             (passwords, "password", "passwords"), (cookies, "cookie", "cookies")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }.joined(separator: ", ")
        }

        enum Category: String, CaseIterable, Identifiable {
            case spaces = "Spaces", tabs = "Tabs", bookmarks = "Bookmarks", history = "History", passwords = "Passwords", cookies = "Cookies"
            var id: Self { self }
            var section: Section {
                switch self {
                case .spaces, .tabs: .workspace
                case .bookmarks: .bookmarks
                case .history: .history
                case .passwords: .passwords
                case .cookies: .cookies
                }
            }
        }
        var categories: [Category] { Category.allCases.filter { count($0) > 0 } }
        func count(_ category: Category) -> Int {
            switch category {
            case .spaces: spaces
            case .tabs: tabs
            case .bookmarks: bookmarks
            case .history: history
            case .passwords: passwords
            case .cookies: cookies
            }
        }
        struct ReviewItem { let title: String; let detail: String }
        func items(_ category: Category) -> [ReviewItem] {
            let libraries: [BrowserImport.Source]
            switch payload {
            case .arc(let scan): libraries = (scan.reviewedLibrary ?? [:]).sorted { $0.key < $1.key }.map(\.value)
            case .browser(let source): libraries = [source]
            }
            switch category {
            case .spaces:
                guard case .arc(let scan) = payload else { return [] }
                return scan.sidebar.spaces.map {
                    ReviewItem(title: $0.title, detail: "\(ArcSidebar.flatten($0.pinned).count + ArcSidebar.flatten($0.today).count) tabs · \($0.profileDirectory)")
                }
            case .tabs:
                guard case .arc(let scan) = payload else { return [] }
                let panes = scan.sidebar.spaces.flatMap { ArcSidebar.flatten($0.pinned) + ArcSidebar.flatten($0.today) }
                return panes.map { ReviewItem(title: $0.customName ?? $0.title, detail: $0.url.absoluteString) }
                    + scan.sidebar.favourites.sorted { $0.key < $1.key }.flatMap { $0.value }.map {
                        ReviewItem(title: $0.host() ?? "Favorite", detail: $0.absoluteString)
                    }
            case .bookmarks:
                return libraries.flatMap(\.bookmarks).map { ReviewItem(title: $0.title, detail: $0.url.absoluteString) }
            case .history:
                return libraries.flatMap(\.visits).sorted { $0.at > $1.at }.map {
                    ReviewItem(title: $0.title, detail: "\($0.url.absoluteString) · \($0.at.formatted(date: .abbreviated, time: .shortened))")
                }
            case .passwords, .cookies: return []
            }
        }
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var candidates: [Candidate] = []
    @Published var selectedID: String?
    @Published private var excludedSections: [String: Set<Section>] = [:]
    @Published private(set) var status = "Looking for browsers…"
    @Published private(set) var progress = 0.0
    @Published private(set) var issues: [ReadIssue] = []
    @Published private(set) var unavailableBrowsers: [String] = []
    @Published private(set) var result = ""
    private let store: TabStore
    private let home: URL
    private let readSource: @Sendable (BrowserProfile) throws -> BrowserImport.Source
    private var generation = UUID()
    var selected: Candidate? { candidates.first { $0.id == selectedID } }
    var isBusy: Bool { phase == .scanning || phase == .importing }
    var canConfirm: Bool {
        phase == .review && selected.map { candidate in
            candidate.sections.contains { isIncluded($0, in: candidate) }
        } == true
    }
    func isIncluded(_ section: Section, in candidate: Candidate) -> Bool {
        !(excludedSections[candidate.id]?.contains(section) ?? false)
    }
    func setIncluded(_ included: Bool, section: Section, in candidate: Candidate) {
        guard phase == .review else { return }
        if included { excludedSections[candidate.id, default: []].remove(section) }
        else { excludedSections[candidate.id, default: []].insert(section) }
    }
    var accessBrowsers: [String] {
        Array(Set(unavailableBrowsers + issues.filter { $0.kind == .accessDenied }.map(\.browser))).sorted()
    }

    private func recordIssue(browser: String, profile: String, error: any Error) {
        let kind = (error as? BrowserImport.Failure)?.kind ?? (BrowserImport.accessDenied(error) ? .accessDenied : .unavailable)
        if let index = issues.firstIndex(where: { $0.browser == browser && $0.kind == kind }) {
            issues[index].details.append(.init(profile: profile, message: error.localizedDescription))
        } else {
            issues.append(ReadIssue(browser: browser, kind: kind, details: [.init(profile: profile, message: error.localizedDescription)]))
        }
    }

    init(store: TabStore, home: URL = BrowserImport.sourceHome,
         readSource: @escaping @Sendable (BrowserProfile) throws -> BrowserImport.Source = { try BrowserImport.readSource(from: $0) }) {
        self.store = store; self.home = home; self.readSource = readSource
    }

    func scan() async {
        guard phase != .importing else { return }
        let token = UUID()
        generation = token
        phase = .scanning; status = "Looking for browsers…"; progress = 0
        candidates = []; selectedID = nil; issues = []; unavailableBrowsers = []; result = ""
        do {
            let home = home
            let readSource = readSource
            let installed = WelcomeImportSource.installedNames
            let discovery = try await ImportWork.run { BrowserImport.discover(home: home, installedBrowsers: installed) }
            try Task.checkCancellation()
            guard token == generation else { return }
            let profiles = discovery.profiles
            unavailableBrowsers = discovery.unavailable
            let total = Double(profiles.count + 1)
            status = "Checking Arc…"
            let arcRoot = home.appendingPathComponent("Library/Application Support/Arc")
            let hasArcSource = installed.contains("Arc") || profiles.contains { $0.browser == "Arc" }
                || FileManager.default.fileExists(atPath: arcRoot.appendingPathComponent("StorableSidebar.json").path)
            var arcScan: ArcImport.Scan?
            if hasArcSource {
                do { arcScan = try await ArcImport.checkedScan(arcRoot) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    recordIssue(browser: "Arc", profile: "Spaces & tabs", error: error)
                }
            }
            if var scan = arcScan {
                try Task.checkCancellation()
                guard token == generation else { return }
                let tabs = scan.sidebar.spaces.reduce(0) {
                    $0 + ArcSidebar.flatten($1.pinned).count + ArcSidebar.flatten($1.today).count
                } + scan.sidebar.favourites.values.reduce(0) { $0 + $1.count }
                var library: [String: BrowserImport.Source] = [:]
                for directory in scan.directories {
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    status = "Reading Arc · \(directory)…"
                    let path = scan.userData.appendingPathComponent(directory)
                    let profile = BrowserProfile(browser: "Arc", profile: directory, path: path,
                        hasHistory: FileManager.default.fileExists(atPath: path.appendingPathComponent("History").path),
                        hasBookmarks: FileManager.default.fileExists(atPath: path.appendingPathComponent("Bookmarks").path))
                    do { library[directory] = try await ImportWork.run { try readSource(profile) } }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard token == generation else { return }
                        recordIssue(browser: "Arc", profile: directory, error: error)
                    }
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                scan.reviewedLibrary = library
                candidates.append(Candidate(id: "arc", browser: "Arc", profile: "All profiles",
                    spaces: scan.sidebar.spaces.count, tabs: tabs,
                    bookmarks: library.values.reduce(0) { $0 + $1.bookmarks.count },
                    history: library.values.reduce(0) { $0 + $1.visits.count },
                    passwords: scan.passwordCount, cookies: scan.cookieCount, payload: .arc(scan)))
            }
            guard token == generation else { return }
            progress = 1 / total
            for (index, profile) in profiles.enumerated() {
                try Task.checkCancellation()
                guard token == generation else { return }
                status = "Reading \(profile.browser) · \(profile.profile)…"
                // The complete Arc importer also brings its browser library; don't show
                // duplicate per-profile Arc choices beside the full installation.
                if profile.browser != "Arc" || !candidates.contains(where: { $0.id == "arc" }) {
                    do {
                        let source = try await ImportWork.run { try readSource(profile) }
                        try Task.checkCancellation()
                        guard token == generation else { return }
                        if !source.visits.isEmpty || !source.bookmarks.isEmpty {
                            candidates.append(Candidate(id: profile.path.path, browser: profile.browser, profile: profile.profile,
                                spaces: 0, tabs: 0, bookmarks: source.bookmarks.count, history: source.visits.count,
                                passwords: 0, cookies: 0, payload: .browser(source)))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard token == generation else { return }
                        recordIssue(browser: profile.browser, profile: profile.profile, error: error)
                    }
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                progress = Double(index + 2) / total
            }
            guard token == generation else { return }
            selectedID = candidates.first?.id
            status = candidates.isEmpty ? "No readable browser data found." : "Ready to bring over."
            phase = .review
        } catch is CancellationError {
            if token == generation { phase = .idle }
        } catch {
            guard token == generation else { return }
            status = "Couldn’t check your browsers. Try again."
            phase = .failed
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        generation = UUID(); phase = .idle
    }

    func confirm() async {
        guard canConfirm, let selected else { return }
        let included = Set(Section.allCases.filter { isIncluded($0, in: selected) })
        let accepted = selected.payload(including: included)
        let destination = store.profileID
        guard !store.isPrivate, ProfileManager.shared.profiles.contains(where: { $0.id == destination }) else {
            status = "Choose a regular Vane profile before importing."; phase = .failed; return
        }
        phase = .importing
        status = "Importing from \(selected.browser)…"
        do {
            switch accepted {
            case .arc(let snapshot):
                let counts = try await ArcImport.apply(snapshot)
                result = ArcImport.report(counts)
            case .browser(let snapshot):
                let counts = try await BrowserImport.importSnapshot(snapshot, profileID: destination) { [weak store] in
                    guard let store else { return false }
                    return !store.isPrivate && store.profileID == destination
                        && ProfileManager.shared.profiles.contains(where: { $0.id == destination })
                }
                result = "Imported \(counts.bookmarks) bookmark\(counts.bookmarks == 1 ? "" : "s") and \(counts.history) history entr\(counts.history == 1 ? "y" : "ies")."
            }
            rebuild()
            BookmarkManager.refresh(profileID: destination)
            phase = .complete
        } catch is CancellationError {
            status = "Import stopped. Completed changes were kept."; phase = .failed
        } catch {
            status = "Couldn’t finish importing. \(error.localizedDescription)"; phase = .failed
        }
    }
}

struct OnboardingImportView: View {
    @ObservedObject var flow: OnboardingImport
    let palette: WelcomePalette
    @State private var waitingForSettings = false
    @State private var settingsFailed = false
    var body: some View {
        VStack(spacing: 20) {
            if flow.phase == .scanning {
                ProgressView(value: flow.progress).frame(maxWidth: 340)
                Text(flow.status).foregroundStyle(palette.muted)
            } else if flow.phase == .importing {
                ProgressView().controlSize(.small)
                Text(flow.status)
                Text("Keep Vane open while your data comes over.")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            } else if flow.phase == .complete {
                Image(systemName: "checkmark.circle").font(.system(size: 40, weight: .light))
                Text(flow.result).multilineTextAlignment(.center)
            } else {
                if flow.phase == .failed {
                    Label(flow.status, systemImage: "exclamationmark.circle")
                        .multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently)
                }
                if flow.candidates.isEmpty {
                    Image(systemName: "tray").font(.system(size: 32, weight: .light)).foregroundStyle(palette.muted)
                    Text(flow.status).multilineTextAlignment(.center)
                    Text("Vane checks your browsers automatically. macOS may require access in Privacy & Security for protected browser data.")
                        .font(.system(size: 12)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 8) {
                        ForEach(flow.candidates) { candidate in
                            Button { flow.selectedID = candidate.id } label: {
                                HStack(spacing: 14) {
                                    if let source = WelcomeImportSource(rawValue: candidate.browser), let icon = source.icon {
                                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34)
                                    } else { Image(systemName: "globe").frame(width: 34, height: 34) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(candidate.browser) · \(candidate.profile)").font(.system(size: 14, weight: .medium))
                                        Text("Found \(candidate.summary.isEmpty ? "browser data" : candidate.summary)")
                                            .font(.system(size: 12)).foregroundStyle(palette.muted)
                                    }
                                    Spacer(minLength: 10)
                                    Image(systemName: flow.selectedID == candidate.id ? "checkmark.circle.fill" : "circle")
                                }.padding(15).contentShape(.rect)
                                    .background(palette.surface, in: .rect(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(flow.selectedID == candidate.id ? palette.ink.opacity(0.5) : .clear, lineWidth: 1))
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(flow.selectedID == candidate.id ? .isSelected : [])
                        }
                    }
                    if let candidate = flow.selected {
                        OnboardingImportReview(candidate: candidate, flow: flow, palette: palette).id(candidate.id)
                    }
                    Text("Nothing in your other browser changes. macOS may ask for its Keychain key if you include Arc passwords or cookies.")
                        .font(.system(size: 12)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
                }
                if !flow.accessBrowsers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(flow.accessBrowsers, id: \.self) { browser in
                            HStack(spacing: 10) {
                                Image(systemName: "lock").foregroundStyle(palette.muted)
                                Text(browser).fontWeight(.medium)
                                Spacer()
                                Text("Can’t check data").foregroundStyle(palette.muted)
                            }
                        }
                        Text("macOS blocked this check. To allow automatic import, enable \(ImportPrivacySettings.appName) in Full Disk Access. Browsing and readable imports work without it.")
                            .foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button {
                                waitingForSettings = ImportPrivacySettings.open()
                                settingsFailed = !waitingForSettings
                            } label: {
                                Label("Open Settings", systemImage: "gearshape")
                            }.buttonStyle(.bordered).controlSize(.regular)
                            Text("We’ll check again when you return.").foregroundStyle(palette.muted)
                        }
                        if settingsFailed { Text("Open System Settings → Privacy & Security → Full Disk Access.").foregroundStyle(palette.muted) }
                        DisclosureGroup("Why this access?") {
                            Text("Full Disk Access is a broad macOS permission. Vane uses its import access to read protected browser files without changing the source. You can revoke it after importing. Permission alone doesn’t confirm that a browser has data to import.")
                                .foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }.font(.system(size: 12)).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surface, in: .rect(cornerRadius: 14))
                }
                let otherIssues = flow.issues.filter { $0.kind != .accessDenied }
                if !otherIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Some data wasn’t included").fontWeight(.medium)
                        ForEach(otherIssues) { issue in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.browser).fontWeight(.medium)
                                Text(issue.guidance).foregroundStyle(palette.muted)
                                DisclosureGroup("Details") {
                                    Text(issue.details.map { $0.profile + " · " + $0.message }.joined(separator: "\n"))
                                        .foregroundStyle(palette.muted).textSelection(.enabled)
                                }
                            }
                        }
                    }.font(.system(size: 12)).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surface, in: .rect(cornerRadius: 14))
                }
                Button("Check again") { Task { await flow.scan() } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }.frame(width: 550).font(.system(size: 14))
            .disclosureGroupStyle(WelcomeDisclosureStyle())
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard waitingForSettings else { return }
                waitingForSettings = false
                Task { await flow.scan() }
            }
    }
}

/// Keep DisclosureGroup's expansion state while making its complete header one button.
private struct WelcomeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Motion.animate(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 16).transition(.opacity)
            }
        }
    }
}

/// Selecting a source exposes its reviewed snapshot, before any destination write.
struct OnboardingImportReview: View {
    let candidate: OnboardingImport.Candidate
    @ObservedObject var flow: OnboardingImport
    let palette: WelcomePalette
    @State private var category: OnboardingImport.Candidate.Category

    init(candidate: OnboardingImport.Candidate, flow: OnboardingImport, palette: WelcomePalette) {
        self.candidate = candidate; self.flow = flow; self.palette = palette
        _category = State(initialValue: candidate.categories.first ?? .bookmarks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to import").font(.system(size: 14, weight: .medium))
            VStack(spacing: 8) {
                ForEach(candidate.sections) { section in
                    HStack {
                        Toggle(section.rawValue, isOn: Binding(
                            get: { flow.isIncluded(section, in: candidate) },
                            set: { flow.setIncluded($0, section: section, in: candidate) }
                        )).toggleStyle(.checkbox)
                        Spacer(minLength: 12)
                        Text(candidate.countLabel(section)).foregroundStyle(palette.muted).lineLimit(1)
                    }.frame(height: 18)
                }
            }.font(.system(size: 12))
            Divider()
            Text("Review found items").font(.system(size: 12, weight: .medium))
            Picker("Found items", selection: $category) {
                ForEach(candidate.categories) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity).frame(height: 24)
            VStack(alignment: .leading, spacing: 8) {
                if !flow.isIncluded(category.section, in: candidate) {
                    Text("\(category.rawValue) won’t be imported.")
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                if category == .passwords || category == .cookies {
                    Text("\(candidate.count(category)) \(category.rawValue.lowercased()) found. Their contents stay hidden here. Only selected sections are decrypted after you confirm; macOS may ask for Keychain access.")
                        .font(.system(size: 12)).foregroundStyle(palette.muted)
                } else {
                    let items = candidate.items(category)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(items[index].title.isEmpty ? items[index].detail : items[index].title)
                                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(items[index].detail).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
                                if index < items.count - 1 { Divider() }
                            }
                        }
                    }
                    .frame(height: min(190, CGFloat(items.count) * 50))
                    .accessibilityLabel("Found \(category.rawValue.lowercased()) in \(candidate.browser)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).frame(width: 550, alignment: .leading)
            .background(palette.surface, in: .rect(cornerRadius: 14))
    }
}

@MainActor enum ImportPrivacySettings {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Vane" }
    static func open() -> Bool {
        NSWorkspace.shared.open(fullDiskAccess)
            || NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
