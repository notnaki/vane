import AppKit

// Only the dependencies outside AppIcon are replaced. Preferences are isolated;
// all catalogue, migration, availability, and selection behavior is production code.
extension UserDefaults {
    @MainActor static let iconTestDomain = "io.github.notnaki.vane.icon-test.\(UUID().uuidString)"
    @MainActor static let vane = UserDefaults(suiteName: iconTestDomain)!
}
@MainActor enum CustomAppIcon {
    static let name = "Custom"
    static var custom: NSImage? { nil }
}

@main @MainActor struct IconMigrationHarness {
    static func main() {
        defer { UserDefaults.vane.removePersistentDomain(forName: UserDefaults.iconTestDomain) }
        var failures = AppIcon.check().filter { !$0.1 }.map(\.0)
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let packaged = CommandLine.arguments.contains("--packaged")
        if packaged { _ = NSApplication.shared }
        expect(AppIcon.variants.count == (packaged ? 9 : 1), "all expected images load")
        if packaged {
            expect(AppIcon.variants.contains { $0.name == "Fluted Glass Dark" },
                   "the dark fluted finish loads from the bundled catalogue")
        }
        for (legacy, canonical) in [("Default", "Dark"), ("Glass", "Normal"), ("Navy", "Normal")] {
            UserDefaults.vane.set(legacy, forKey: AppIcon.key)
            AppIcon.restoreAtLaunch()
            expect(UserDefaults.vane.string(forKey: AppIcon.key) == canonical,
                   "\(legacy) retains canonical choice \(canonical), including without assets")
            expect(AppIcon.current == (packaged ? canonical : "Dark"),
                   "\(legacy) availability fallback is temporary")
        }
        UserDefaults.vane.set("Custom", forKey: AppIcon.key)
        AppIcon.restoreAtLaunch()
        expect(UserDefaults.vane.string(forKey: AppIcon.key) == "Custom", "missing custom file preserves saved choice")
        if packaged {
            for variant in AppIcon.catalogue {
                AppIcon.apply(variant.name)
                expect(AppIcon.current == variant.name, "selecting \(variant.name) persists its choice")
            }
        }
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
        print("PASS: icon catalogue, migration, and \(packaged ? "bundled selection" : "missing-asset fallback")")
    }
}
