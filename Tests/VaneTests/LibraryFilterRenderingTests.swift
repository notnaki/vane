import AppKit
import SwiftUI
import Vision
import XCTest
@testable import vane

@MainActor final class LibraryFilterRenderingTests: XCTestCase {
    func testInlinePanelFitsNarrowColumnAndSearchReclaimsFocus() async throws {
        TestEnvironment.prepare()
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            try await exercisePanel(isPrivate: false)
            try await exercisePanel(isPrivate: true)
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup: \(error)") } }
        if let failure { throw failure }
    }

    private func exercisePanel(isPrivate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileManager(directory: directory, sandboxed: true)
        _ = profiles.create(name: "school")
        _ = profiles.create(name: "sparc dev")
        let library = Library.shared
        let previous = (library.section, library.query, library.profileFilters, library.filterSection)
        let store = TabStore(isPrivate: isPrivate, profileID: UUID(), session: [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: Look.libraryList, height: 330),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil
            Library.open(previous.0, in: store)
            library.query = previous.1; library.profileFilters = previous.2; library.filterSection = previous.3
            store.libraryOpen = false; store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        try await LibraryFocusFixture.admitForeground(window)
        Library.open(.downloads, in: store)
        let host = NSHostingView(rootView:
            VStack(spacing: 0) {
                LibraryHead(section: .downloads, filtering: false, query: Binding(get: { library.query }, set: { library.query = $0 }),
                            filter: { Toggle("Completed only", isOn: .constant(false)) },
                            actions: { Button("Clear Downloads") {} }, profiles: profiles)
                Text("Today").font(Look.libraryGroupText.font).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Look.inset + 4).padding(.top, Look.inset)
                Spacer()
            }.background(Look.panelFill).environmentObject(store).preferredColorScheme(.dark)
        )
        window.contentView = host
        func editorPrompt() -> String? {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
        }
        try await LibraryFocusFixture.wait("Downloads editor", in: window) {
            editorPrompt() == LibrarySection.downloads.searchPrompt
        }
        if !isPrivate {
            let searchWords = try await strings(host).joined(separator: " ")
            XCTAssertTrue(searchWords.contains("Filter"), "Filter label clipped: \(searchWords)")
        }
        library.filterSection = .downloads
        try await compatibilityWait { try await self.strings(host).contains { $0.contains("Filter Downloads") } }
        let words = try await strings(host).joined(separator: " ")
        for expected in ["Filter Downloads", "Done", "Today"] + (isPrivate ? [] : ["Profiles", "Personal", "school", "sparc dev"]) {
            XCTAssertTrue(words.contains(expected), "Missing or clipped \(expected): \(words)")
        }
        XCTAssertFalse(words.contains("Completed only"), "Additional filters belong in More, leaving results below Profiles")
        if isPrivate {
            for hidden in ["Profiles", "Personal", "school", "sparc dev"] {
                XCTAssertFalse(words.contains(hidden), "Private Library leaked \(hidden): \(words)")
            }
        }
        try capture(host, name: isPrivate ? "private-panel" : "panel")
        library.focusSearch()
        try await LibraryFocusFixture.wait("Downloads editor after Done / Find", in: window) {
            editorPrompt() == LibrarySection.downloads.searchPrompt && library.filterSection == nil
        }
        try await compatibilityWait { try await self.strings(host).contains { $0.contains("Filter") } }
        // Text input from the shared desktop must not enter the delivered capture.
        library.query = ""
        try await LibraryFocusFixture.wait("empty preview search", in: window) {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.stringValue == ""
        }
        let returnedWords = try await strings(host)
        XCTAssertFalse(returnedWords.contains { $0.contains("Filter Downloads") })
        try capture(host, name: isPrivate ? "private-search" : "search")
    }

    private func strings(_ host: NSView) async throws -> [String] {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["VANE_LIBRARY_FILTER_CAPTURES"] else { return }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name).png"))
    }
}
