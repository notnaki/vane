import AppKit

// Only the dependencies outside AppIcon are replaced. Preferences are isolated;
// all catalogue, migration, availability, and selection behavior is production code.
extension UserDefaults {
    @MainActor static let iconTestDomain = ProcessInfo.processInfo.environment["VANE_ICON_TEST_DOMAIN"]
        ?? "io.github.notnaki.vane.icon-test.\(UUID().uuidString)"
    @MainActor static let vane = UserDefaults(suiteName: iconTestDomain)!
}
// Objective-C fixtures exercise the optional selector bridge, including older/future
// system classes with missing methods. The appearance value is never changed by refresh.
@MainActor final class IconAppearanceFixture: NSObject {
    static let current = IconAppearanceFixture()
    let appearance = "dark"
    var savedAppearance: String?
    @objc static func fetchCurrentIconAppearanceConfiguration() -> IconAppearanceFixture { current }
    @objc func save() { savedAppearance = appearance }
}
@MainActor final class IconAppearanceWithoutSave: NSObject {
    @objc static func fetchCurrentIconAppearanceConfiguration() -> NSObject { NSObject() }
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
        AppIconPersistence.refreshDockIconCache(configurationClass: nil)
        AppIconPersistence.refreshDockIconCache(configurationClass: NSObject.self)
        AppIconPersistence.refreshDockIconCache(configurationClass: IconAppearanceWithoutSave.self)
        AppIconPersistence.refreshDockIconCache(configurationClass: IconAppearanceFixture.self)
        expect(IconAppearanceFixture.current.savedAppearance == "dark",
               "Dock refresh re-publishes the existing appearance without changing it")
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
        func luminance(_ image: NSImage?) -> CGFloat {
            guard let image else { return 1 }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                      bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
            NSGraphicsContext.restoreGraphicsState()
            // A point on the tile beside the V, away from its glow and the edge.
            let color = rep.colorAt(x: 28, y: 64)!.usingColorSpace(.sRGB)!
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let packaged = CommandLine.arguments.contains("--packaged")
        if let index = CommandLine.arguments.firstIndex(of: "--persistence") {
            _ = NSApplication.shared
            let choice = CommandLine.arguments[index + 1]
            expect(AppIcon.isSandboxed == CommandLine.arguments.contains("--sandboxed"),
                   "fixture exercises the intended sandbox path")
            if choice == "cleanup" {
                if AppIcon.isSandboxed { _ = AppIconPersistence.setIcon(nil) }
                else { _ = NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: []) }
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
            } else if choice != "verify" {
                AppIcon.apply(choice)
            }
            UserDefaults.vane.synchronize()
            var finderInfo = [UInt8](repeating: 0, count: 32)
            let count = getxattr(Bundle.main.bundlePath, "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
            let hasCustomIcon = count == 32 && finderInfo[8] & 0x04 != 0
            expect(hasCustomIcon,
                   "the bundle retains its selected icon after the first process exits (\(choice))")
            let preview = AppIcon.variants.first { $0.name == AppIcon.current }!.image
            let finder = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            expect(abs(luminance(finder) - luminance(preview)) < 0.08,
                   "Finder immediately resolves the selected image, including in a fresh process (\(choice))")
            failures.forEach { print("FAIL: \($0)") }
            exit(failures.isEmpty ? 0 : 1)
        }
        if packaged { _ = NSApplication.shared }
        expect(AppIcon.variants.count == (packaged ? 9 : 1), "all expected images load")
        if packaged {
            let dark = AppIcon.variants.first { $0.name == "Dark" }!.image
            let normal = AppIcon.variants.first { $0.name == "Normal" }!.image
            expect(luminance(dark) < 0.22 && luminance(normal) - luminance(dark) > 0.06,
                   "Dark offers the black artwork rather than duplicating Normal (dark: \(luminance(dark)), normal: \(luminance(normal)))")
            AppIcon.apply("Fluted Glass Dark")
            AppIcon.apply("Dark")
            expect(luminance(NSApp.applicationIconImage) < 0.22,
                   "switching from Fluted to Dark installs the black image in the live Dock")
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
