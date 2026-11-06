import Foundation

/// Speeds are read at the next interaction, including by native completion clocks.
/// Keep this independent of the main actor: Look also serves headless checks.
enum UIAnimation: String, CaseIterable, Identifiable, Sendable {
    case sidebar, tabList, tabClosing, surfaces, feedback, status

    var id: String { rawValue }
    var key: String { "uiAnimationSpeed." + rawValue }
    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    var title: String {
        switch self {
        case .sidebar: "Sidebar"
        case .tabList: "Tabs and folders"
        case .tabClosing: "Closing tabs"
        case .surfaces: "Floating panels"
        case .feedback: "Hover and selection"
        case .status: "Link status"
        }
    }

    var detail: String {
        switch self {
        case .sidebar: "Show, hide, and reveal the floating sidebar."
        case .tabList: "Move tabs, expand folders, and rearrange lists."
        case .tabClosing: "Fade out closed tabs and sweep Today’s tabs away."
        case .surfaces: "Show and dismiss search, Peek, tooltips, and Library."
        case .feedback: "Highlight buttons, menus, and selected items."
        case .status: "Fade the hovered link’s address in and out."
        }
    }

    static func normalized(_ speed: Double) -> Double {
        speeds.contains(speed) ? speed : 1
    }

    func speed(in defaults: UserDefaults = .vane) -> Double {
        Self.normalized(defaults.double(forKey: key))
    }

    func duration(_ seconds: Double) -> Double { seconds / speed() }

    func reset(in defaults: UserDefaults = .vane) { defaults.removeObject(forKey: key) }

    static func resetAll(in defaults: UserDefaults = .vane) {
        for animation in allCases { animation.reset(in: defaults) }
    }

    static func search(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return allCases.filter { animation in
            let text = animation.title + " " + animation.detail
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    static func speedLabel(_ speed: Double) -> String {
        let value = speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
        return speed == 1 ? value + " (Default)" : value
    }
}
