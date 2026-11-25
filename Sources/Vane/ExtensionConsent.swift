import AppKit
import WebKit

/// The reviewed manifest access, independently of WebKit's session/runtime grants.
/// Exact pattern comparisons deliberately err toward another review rather than silently
/// treating a wider host or path wildcard as already approved.
struct ExtensionAccess: Codable, Equatable, Sendable {
    let permissions: Set<String>
    let sites: Set<String>

    @MainActor init(_ ext: WKWebExtension) {
        // WebKit does not know `debugger`; Vane provides it, so the review must name it.
        permissions = Set(ext.requestedPermissions.map(\.rawValue))
            .union(ExtensionDebuggerAPI.declared(ext.manifest) ? [ExtensionDebuggerAPI.permission] : [])
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

    static func phrase(_ permission: String) -> String {
        switch permission {
        case "activeTab": "Access the active page when you use the extension"
        case "alarms": "Schedule extension tasks"
        case "clipboardWrite": "Write to your clipboard"
        case "contextMenus", "menus": "Add items to page and tab menus"
        case "cookies": "Read and change website cookies"
        case "debugger": "Control pages you allow it on: read them, click, type and take screenshots"
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
    nonisolated static let baseKey = "extensionConsent.v1"

    struct NativeMessagingErrorReview { let name: String }

    static func makeNativeMessagingErrorPrompt(_ review: NativeMessagingErrorReview) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Enable error-only desktop compatibility for “\(review.name)”?"
        alert.informativeText = "The extension can receive errors when it requests desktop integration. Vane will not connect to desktop apps. Desktop-dependent features remain unavailable."
        alert.addButton(withTitle: "Enable Error-Only Mode")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func askNativeMessagingErrors(_ review: NativeMessagingErrorReview) -> Bool {
        makeNativeMessagingErrorPrompt(review).runModal() == .alertFirstButtonReturn
    }

    struct Review {
        let name: String
        let requested: ExtensionAccess
        let previous: ExtensionAccess?
        let installing: Bool
        var limitations: [String] = []
        var newlySupportedCapabilities: Set<String> = []
        var updating = false
        var currentVersion: String? = nil
        var candidateVersion: String? = nil
        var verifiedSigner: String? = nil

        var needsApproval: Bool {
            installing || updating || !newlySupportedCapabilities.isEmpty || previous.map { !requested.additions(over: $0).isEmpty } ?? true
        }

        /// A capability Vane or WebKit lacks can break the extension's core features (issue #746).
        /// A saved line for a capability Vane has since gained support for is stale, not missing.
        var hasUnsupportedCapabilities: Bool {
            limitations.contains {
                ExtensionDiagnostics.isUnsupported($0)
                    && !newlySupportedCapabilities.contains(String($0.prefix { $0 != ":" }))
            }
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

    static let unsupportedWarning = "Some features of this extension may not work in Vane: it uses features Vane doesn’t support. See Compatibility limitations below."

    static func makePrompt(_ review: Review) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = review.installing ? "Install “\(review.name)”?"
            : !review.newlySupportedCapabilities.isEmpty ? "Review new support for “\(review.name)”"
            : review.updating ? "Update “\(review.name)”?"
            : review.previous == nil ? "Review access for “\(review.name)”"
            : "“\(review.name)” wants more access"
        alert.informativeText = "Review the extension’s capabilities and the websites it can access. "
            + "Allowing website access can let it read and change data on those pages. "
            + (review.installing ? "Cancel leaves it uninstalled."
               : "Don’t Allow keeps the previously accepted version, if available. No new access is granted.")
        if let signer = review.verifiedSigner {
            alert.informativeText = signer + "\n\n" + alert.informativeText
        }
        if review.hasUnsupportedCapabilities {
            alert.informativeText = Self.unsupportedWarning + "\n\n" + alert.informativeText
        }
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
        if review.updating {
            text.string = "Version: " + (review.currentVersion ?? "Unknown") + " → " + (review.candidateVersion ?? "Unknown")
                + "\n\nVane will replace its accepted copy. Source-folder edits apply only after a reviewed update. A disabled extension stays disabled.\n\n" + text.string
        }
        if !review.newlySupportedCapabilities.isEmpty {
            text.string = "Newly available capabilities\n\nVane previously marked these capabilities unavailable. Approving lets this version use them:\n"
                + review.newlySupportedCapabilities.sorted().map { "• " + ExtensionAccess.phrase($0) + " (" + $0 + ")" }.joined(separator: "\n")
                + "\n\n" + text.string
        }
        if !review.limitations.isEmpty {
            text.string += "\n\nCompatibility limitations\n\n" + review.limitations.joined(separator: "\n")
        }
        style(text)
        text.drawsBackground = false
        // Fit short lists; long ones scroll.
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 240) + 16
        text.frame.size.height = min(max(used, 60), 260)
        let scroll = NSScrollView(frame: text.frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: review.installing ? "Install Extension" : review.updating ? "Update Extension" : "Allow and Enable").keyEquivalent = ""
        // A button holds one key equivalent: Escape denies, as macOS cancel buttons do.
        // Nothing answers Return, so the key can never grant access.
        alert.addButton(withTitle: review.installing ? "Cancel" : "Don’t Allow").keyEquivalent = "\u{1b}"
        return alert
    }

    static let headings: Set<String> = ["Capabilities", "Website access", "Compatibility limitations",
                                        "New access", "All requested access", "Newly available capabilities"]

    /// Styles the plain review text in place: headings in semibold, the capability name
    /// before a limitation's colon in medium, and air between lines. The string itself
    /// is unchanged.
    static func style(_ text: NSTextView) {
        guard let storage = text.textStorage else { return }
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 3
        storage.setAttributes([.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph],
                              range: NSRange(location: 0, length: storage.length))
        var inLimitations = false
        let string = storage.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            if headings.contains(line) {
                inLimitations = line == "Compatibility limitations"
                storage.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                                       .foregroundColor: NSColor.secondaryLabelColor], range: range)
            } else if inLimitations, let colon = line.firstIndex(of: ":") {
                let name = NSRange(location: range.location, length: line.distance(from: line.startIndex, to: colon))
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), range: name)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                     range: NSRange(location: NSMaxRange(name), length: range.length - name.length))
            }
        }
    }

    static func ask(_ review: Review) -> Bool {
        makePrompt(review).runModal() == .alertFirstButtonReturn
    }
}
