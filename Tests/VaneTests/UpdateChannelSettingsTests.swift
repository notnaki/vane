import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class UpdateChannelSettingsTests: XCTestCase {
    func testChannelControlAndExplanationFitBothThemes() throws {
        TestEnvironment.prepare()
        for channel in UpdateChannel.allCases {
            for dark in [false, true] {
                let content = SettingsCard {
                    UpdateChannelSettings(selection: .constant(channel.rawValue))
                }
                .padding(20)
                .frame(width: 520)
                .background(dark ? Color(white: 0.12) : .white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                let fitting = host.fittingSize
                XCTAssertEqual(fitting.width, 520, accuracy: 1)
                XCTAssertLessThan(fitting.height, 180, "The setting and its explanation should fit a compact card")
                XCTAssertGreaterThan(fitting.height, 80, "The explanation must remain visible")
                host.frame = NSRect(origin: .zero, size: fitting)
                host.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                if let directory = ProcessInfo.processInfo.environment["VANE_UPDATE_CHANNEL_SNAPSHOTS"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("\(channel.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
