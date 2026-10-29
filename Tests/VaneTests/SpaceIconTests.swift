import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceIconTests: XCTestCase {
    func testArcEmojiAndObviousBuiltInIconsSurviveParsing() throws {
        let icons: [[String: Any]] = [["emoji_v2": "🤖", "emoji": 129302],
            ["emoji_v2": "🖥️"], ["emoji": 129302], ["icon": "leaf"], ["icon": "star"],
            ["icon": "not-a-supported-arc-icon"], ["emoji_v2": "not emoji"]]
        let spaces = icons.enumerated().map { index, icon in
            ["id": "space-\(index)", "title": "Space", "profile": ["default": true],
             "customInfo": ["iconType": icon]] as [String: Any]
        }
        let json: [String: Any] = ["sidebar": ["containers": [["spaces": spaces, "items": []]]]]
        let parsed = try XCTUnwrap(ArcSidebar.parse(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(parsed.spaces.map(\.icon), ["🤖", "🖥️", "🤖", "leaf", "star", nil, nil])
    }

    func testEmojiInputKeepsAWholeGraphemeAndRejectsOrdinaryText() {
        for emoji in ["🤖", "🖥️", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇹🇷", "1️⃣"] {
            XCTAssertEqual(Spaces.emojiIcon(emoji + " extra text"), emoji)
        }
        for invalid in ["", "hello", "123", "cloud", " \n", "é"] {
            XCTAssertNil(Spaces.emojiIcon(invalid))
        }
    }

    func testPersistedEmojiAndNativeMenuImageKeepTheirArtwork() throws {
        TestEnvironment.prepare()
        let original = Space(name: "Desktop", profileID: UUID(), icon: "🖥️")
        let restored = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.icon, original.icon)
        let emoji = try XCTUnwrap(Spaces.iconImage("🖥️"))
        XCTAssertFalse(emoji.isTemplate, "Emoji must keep its color in native menus")
        XCTAssertNotNil(Spaces.iconImage("leaf"))
        let render = ImageRenderer(content: SpaceIcon("👩🏽‍💻").font(.system(size: 24)).frame(width: 48, height: 48))
        let image = try XCTUnwrap(render.cgImage)
        let pixels = NSBitmapImageRep(cgImage: image)
        XCTAssertTrue((0..<pixels.pixelsHigh).contains { y in
            (0..<pixels.pixelsWide).contains { x in (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        }, "A nonnil but empty image does not establish emoji rendering")
    }
    func testSpacePickerAndPasswordPreferenceFitNativeWidth() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            for scheme in [ColorScheme.light, .dark] {
                try await snapshot(SpaceIconPicker(current: "cloud", pick: { _ in }), scheme: scheme, name: "icons")
                try await snapshot(SpaceIconPicker(current: "🖥️", pick: { _ in }), scheme: scheme, name: "emoji")
                try await snapshot(PasswordSavingPreference(profileID: UUID()).padding(12), scheme: scheme, name: "passwords")
            }
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") } }
        if let failure { throw failure }
    }

    private func snapshot<V: View>(_ view: V, scheme: ColorScheme, name: String) async throws {
        // Native controls require NSHostingView: ImageRenderer substitutes a warning
        // tile for AppKit text fields and cannot validate the actual search input.
        let content = view.frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 340, height: 420),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await LibraryFocusFixture.admitForeground(window)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, 450)
        window.setContentSize(CGSize(width: 340, height: ceil(host.fittingSize.height)))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_FEATURE_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("\(name)-\(scheme).png"))
        }
    }

    func testEmojiCatalogIncludesSearchableNamesAndAllPickerCategories() {
        let entries = SpaceEmojiCatalog.entries
        XCTAssertGreaterThan(entries.count, 3000)
        XCTAssertEqual(Set(entries.map(\.category)), Set(SpaceEmojiCatalog.Category.allCases))
        XCTAssertTrue(SpaceEmojiCatalog.search("robot", category: .nature).contains { $0.emoji == "🤖" },
                      "Search covers every category")
        XCTAssertTrue(SpaceEmojiCatalog.search("flag turkey", category: .people).contains { $0.emoji == "🇹🇷" })
        XCTAssertTrue(SpaceEmojiCatalog.search("", category: .food).allSatisfy { $0.category == .food })
        XCTAssertTrue(entries.contains { $0.emoji == "🖥️" })
        XCTAssertEqual(Set(entries.map(\.emoji)).count, entries.count)
        for symbol in Spaces.pickerIcons { XCTAssertNotNil(Spaces.iconImage(symbol), symbol) }
    }

}
