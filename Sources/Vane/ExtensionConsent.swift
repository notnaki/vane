import AppKit
import WebKit

/// The reviewed manifest access, independently of WebKit's session/runtime grants.
/// Exact pattern comparisons deliberately err toward another review rather than silently
/// treating a wider host or path wildcard as already approved.
struct ExtensionAccess: Codable, Equatable {
    let permissions: Set<String>
    let sites: Set<String>

    @MainActor init(_ ext: WKWebExtension) {
        permissions = Set(ext.requestedPermissions.map(\.rawValue))
        sites = Set(ext.requestedPermissionMatchPatterns.union(ext.allRequestedMatchPatterns).map(\.string))
    }

    init(permissions: Set<String>, sites: Set<String>) {
        self.permissions = permissions
        self.sites = sites
    }

    func additions(over previous: Self) -> Self {
        Self(permissions: permissions.subtracting(previous.permissions),
             sites: sites.subtracting(previous.sites))
    }

    var isEmpty: Bool { permissions.isEmpty && sites.isEmpty }

    var description: String {
        let capabilities = permissions.sorted().map { "• \(Self.phrase($0)) (\($0))" }.joined(separator: "\n")
        let websites = sites.sorted().map {
            $0 == "<all_urls>" || $0 == "*://*/*" ? "• All websites (\($0))" : "• \($0)"
        }.joined(separator: "\n")
        return "Capabilities\n" + (capabilities.isEmpty ? "None requested" : capabilities)
            + "\n\nWebsite access\n" + (websites.isEmpty ? "None requested" : websites)
    }

    private static func phrase(_ permission: String) -> String {
        switch permission {
        case "activeTab": "Access the active page when you use the extension"
        case "alarms": "Schedule extension tasks"
        case "clipboardWrite": "Write to your clipboard"
        case "contextMenus", "menus": "Add items to page menus"
        case "cookies": "Read and change website cookies"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": "Block or modify website requests"
        case "declarativeNetRequestFeedback": "Read information about filtered website requests"
        case "nativeMessaging": "Exchange messages with native apps"
        case "scripting": "Run scripts on websites you allow"
        case "storage": "Store extension data locally"
        case "tabs": "Read tab titles and URLs"
        case "unlimitedStorage": "Store extension data without the normal quota"
        case "webNavigation": "Observe browser navigation"
        case "webRequest": "Observe website requests"
        default: permission
        }
    }
}

@MainActor enum ExtensionConsent {
    static let baseKey = "extensionConsent.v1"

    struct Review {
        let name: String
        let requested: ExtensionAccess
        let previous: ExtensionAccess?
        let installing: Bool

        var needsApproval: Bool {
            installing || previous.map { !requested.additions(over: $0).isEmpty } ?? true
        }
    }

    static func saved(for folder: URL, profileID: UUID,
                      in defaults: UserDefaults = .vane) -> ExtensionAccess? {
        let records = defaults.dictionary(forKey: ProfileManager.defaultsKey(baseKey, profileID))
        guard let data = records?[folder.resolvingSymlinksInPath().path] as? Data else { return nil }
        return try? JSONDecoder().decode(ExtensionAccess.self, from: data)
    }

    static func save(_ access: ExtensionAccess, for folder: URL, profileID: UUID,
                     in defaults: UserDefaults = .vane) throws {
        let data = try JSONEncoder().encode(access)
        let key = ProfileManager.defaultsKey(baseKey, profileID)
        var records = defaults.dictionary(forKey: key) ?? [:]
        records[folder.resolvingSymlinksInPath().path] = data
        defaults.set(records, forKey: key)
    }

    static func remove(for folder: URL, profileID: UUID, in defaults: UserDefaults = .vane) {
        let key = ProfileManager.defaultsKey(baseKey, profileID)
        var records = defaults.dictionary(forKey: key) ?? [:]
        records.removeValue(forKey: folder.resolvingSymlinksInPath().path)
        if records.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(records, forKey: key) }
    }

    static func makePrompt(_ review: Review) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = review.installing ? "Install “\(review.name)”?"
            : review.previous == nil ? "Review access for “\(review.name)”"
            : "“\(review.name)” wants more access"
        alert.informativeText = "Review the extension’s capabilities and the websites it can access. "
            + "Allowing website access can let it read and change data on those pages. "
            + (review.installing ? "Cancel leaves it uninstalled."
               : "Don’t Allow leaves it disabled; choose Install Extension again to review it later.")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        text.isEditable = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        if let previous = review.previous, !review.requested.additions(over: previous).isEmpty {
            text.string = "New access\n\n" + review.requested.additions(over: previous).description
                + "\n\nAll requested access\n\n" + review.requested.description
        } else { text.string = review.requested.description }
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: review.installing ? "Install Extension" : "Allow and Enable")
        alert.addButton(withTitle: review.installing ? "Cancel" : "Don’t Allow").keyEquivalent = "\u{1b}"
        return alert
    }

    static func ask(_ review: Review) -> Bool {
        makePrompt(review).runModal() == .alertFirstButtonReturn
    }
}
