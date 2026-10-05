import AppKit

// Only the dependencies outside AppIcon are replaced. Preferences are isolated;
// all catalogue, migration, availability, and selection behavior is production code.
extension UserDefaults {
    @MainActor static let iconTestDomain = ProcessInfo.processInfo.environment["VANE_ICON_TEST_DOMAIN"]
        ?? "io.github.notnaki.vane.icon-test.\(UUID().uuidString)"
    @MainActor static let vane = UserDefaults(suiteName: iconTestDomain)!
}
@main @MainActor struct IconMigrationHarness {
    static func main() {
        defer {
            if !CommandLine.arguments.contains("--persistence") {
                UserDefaults.vane.removePersistentDomain(forName: UserDefaults.iconTestDomain)
            }
        }
        var failures = AppIcon.check().filter { !$0.1 }.map(\.0)
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let embedded = URL(fileURLWithPath: "/Applications/Vane.app/Contents/XPCServices/io.github.notnaki.vane.IconService.xpc")
        expect(AppIconPersistence.hostBundle(for: embedded)?.path == "/Applications/Vane.app",
               "helper targets only its containing app")
        for path in ["/Applications/Other.app/IconService.xpc",
                     "/Applications/Vane.app/Contents/Other/io.github.notnaki.vane.IconService.xpc",
                     "/tmp/Contents/XPCServices/io.github.notnaki.vane.IconService.xpc",
                     "/tmp/AppTranslocation/A/Vane.app/Contents/XPCServices/io.github.notnaki.vane.IconService.xpc"] {
            expect(AppIconPersistence.hostBundle(for: URL(fileURLWithPath: path)) == nil,
                   "helper refuses an invalid or temporary host")
        }
        let packaged = CommandLine.arguments.contains("--packaged")
        if let index = CommandLine.arguments.firstIndex(of: "--persistence") {
            _ = NSApplication.shared
            let choice = CommandLine.arguments[index + 1]
            expect(AppIcon.isSandboxed == CommandLine.arguments.contains("--sandboxed"),
                   "fixture exercises the intended sandbox path")
            if choice == "cleanup" {
                UserDefaults.vane.removePersistentDomain(forName: UserDefaults.iconTestDomain)
                exit(0)
            }
            if choice == "restore" {
                expect(AppIcon.current == "Galaxy", "the selected icon survives a fresh process")
                AppIcon.restoreAtLaunch()
            } else if choice == "removed-custom" {
                UserDefaults.vane.set("Custom", forKey: AppIcon.key)
                AppIcon.restoreAtLaunch()
                expect(AppIcon.current == "Dark", "removed custom icons revert to Dark")
            } else if choice == "invalid-data" {
                expect(!AppIconPersistence.setIcon(Data([0, 1, 2])), "helper refuses malformed image data")
            } else if choice != "verify" { AppIcon.apply(choice) }
            UserDefaults.vane.synchronize()
            var finderInfo = [UInt8](repeating: 0, count: 32)
            let count = getxattr(Bundle.main.bundlePath, "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
            let hasCustomIcon = count == 32 && finderInfo[8] & 0x04 != 0
            expect(hasCustomIcon == (!["Dark", "removed-custom"].contains(choice)),
                   "the bundle retains its selected icon after the process exits (\(choice))")
            failures.forEach { print("FAIL: \($0)") }
            exit(failures.isEmpty ? 0 : 1)
        }
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
        expect(UserDefaults.vane.string(forKey: AppIcon.key) == "Dark", "removed custom selection falls back to the bundled default")
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
