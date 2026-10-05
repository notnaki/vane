import XCTest
import AppKit
import WebKit
import SwiftUI
@testable import vane

@MainActor final class EaselTests: XCTestCase {
    func testRoundedDiamondSoftensAllFourCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 180)
        let sharp = EaselShape.diamondPath(in: bounds, edges: .sharp)
        let rounded = EaselShape.diamondPath(in: bounds, edges: .round)
        var corners = 0
        rounded.forEach { if case .quadCurve = $0 { corners += 1 } }
        XCTAssertEqual(corners, 4)
        XCTAssertNotEqual(sharp, rounded)
        XCTAssertTrue(bounds.contains(rounded.boundingRect))
    }
    func testZeroOpacityHidesTheEntireNoteInPNGExport() throws {
        var note = EaselItem(kind: .note, text: "Hidden", x: 100, y: 100)
        note.style = EaselObjectStyle(opacity: 0)
        let hidden = try XCTUnwrap(NSBitmapImageRep(data: EaselWindow.png(for: EaselBoard(items: [note]), profileID: UUID())))
        let empty = try XCTUnwrap(NSBitmapImageRep(data: EaselWindow.png(for: EaselBoard(), profileID: UUID())))
        let pixel = try XCTUnwrap(hidden.colorAt(x: 200, y: 200)?.usingColorSpace(.deviceRGB))
        let paper = try XCTUnwrap(empty.colorAt(x: 200, y: 200)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(pixel.redComponent, paper.redComponent, accuracy: 0.01)
        XCTAssertEqual(pixel.greenComponent, paper.greenComponent, accuracy: 0.01)
        XCTAssertEqual(pixel.blueComponent, paper.blueComponent, accuracy: 0.01)
    }
    private func repository() -> EaselStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return EaselStore(profileID: UUID(), directory: root)
    }
    private func imageItem() throws -> EaselItem {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        return try EaselWindow.imageItem(image, source: "https://example.com")
    }
    func testFailedSaveReturnsFailureAndPreservesCommittedContent() throws {
        let repository = repository()
        let session = EaselSession(repository)
        session.create()
        XCTAssertTrue(session.add(EaselItem(kind: .note, text: "Saved")))
        try FileManager.default.removeItem(at: repository.directory)
        try Data().write(to: repository.directory)
        XCTAssertFalse(session.edit { $0.items[0].text = "Keep this draft" })
        XCTAssertEqual(session.board?.items.first?.text, "Saved")
        XCTAssertNotNil(session.message)
    }
    func testRemovedCapturesReleaseTheirLiveViewSlots() throws {
        let session = EaselSession(repository()); session.create()
        var items: [EaselItem] = []
        for _ in 0..<4 {
            let item = try imageItem(); items.append(item)
            XCTAssertTrue(session.add(item)); session.toggleLive(item.id)
        }
        XCTAssertEqual(session.liveItems.count, 4)
        XCTAssertTrue(session.edit { $0.items.removeAll() })
        XCTAssertTrue(session.liveItems.isEmpty)
        let next = try imageItem(); XCTAssertTrue(session.add(next)); session.toggleLive(next.id)
        XCTAssertEqual(session.liveItems, [next.id])
        session.undo()
        XCTAssertTrue(session.liveItems.isEmpty)
    }
    func testNewItemsFollowTheVisibleCanvasAndStayWithinItsBounds() throws {
        let session = EaselSession(repository()); session.create()
        session.insertionPoint = CGPoint(x: 2500, y: 1800)
        XCTAssertTrue(session.add(EaselItem(kind: .note, text: "Here")))
        XCTAssertEqual(session.board?.items.first?.x, 2500)
        XCTAssertEqual(session.board?.items.first?.y, 1800)
        session.insertionPoint = CGPoint(x: 9000, y: 9000)
        XCTAssertTrue(session.add(EaselItem(kind: .note)))
        XCTAssertEqual(session.board?.items.last?.x, 5720)
        XCTAssertEqual(session.board?.items.last?.y, 3800)
    }
    func testLiveSourceChangesReloadButOrdinaryRerendersKeepNavigation() {
        TestEnvironment.prepare()
        let original = URL(string: "https://example.com/old")!
        let updated = URL(string: "https://example.com/new")!
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        delegate.source = original
        delegate.upgradedHosts.insert("example.com")
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer { web.stopLoading() }
        EaselLiveView.update(web, source: updated, delegate: delegate)
        XCTAssertEqual(delegate.source, updated)
        XCTAssertTrue(delegate.upgradedHosts.isEmpty)
        delegate.upgradedHosts.insert("keep-state")
        EaselLiveView.update(web, source: updated, delegate: delegate)
        XCTAssertEqual(delegate.upgradedHosts, ["keep-state"])
    }
    func testLiveNavigationHonorsHTTPSPolicyAndPreventsDowngradeLoops() {
        let suite = "vane.easel.https-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = HTTPSOnly.defaults; HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; UserDefaults.dropScratchSuite(suite) }
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        let plain = URL(string: "http://example.com/a")!
        XCTAssertEqual(delegate.policy(url: plain, mainFrame: true), .upgrade(URL(string: "https://example.com/a")!))
        XCTAssertEqual(delegate.policy(url: plain, mainFrame: true), .cancel)
        delegate.finished(url: URL(string: "https://example.com/a")!)
        XCTAssertEqual(delegate.policy(url: URL(string: "http://example.com/next")!, mainFrame: true),
                       .upgrade(URL(string: "https://example.com/next")!))
        XCTAssertEqual(delegate.policy(url: URL(string: "http://localhost:8080")!, mainFrame: true), .allow)
        XCTAssertEqual(delegate.policy(url: URL(string: "javascript:alert(1)")!, mainFrame: true), .cancel)
        HTTPSOnly.allow(host: "allowed.example", profileID: delegate.profileID)
        XCTAssertEqual(delegate.policy(url: URL(string: "http://allowed.example")!, mainFrame: true), .allow)
    }
    func testPNGExportIncludesItemsAtTheFarCanvasEdge() throws {
        let board = EaselBoard(items: [EaselItem(kind: .note, text: "Edge", x: 5400, y: 3400)])
        let png = try EaselWindow.png(for: board, profileID: UUID())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 4096)
        let scale = 4096.0 / 5720.0
        let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(5500 * scale), y: Int(3520 * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.95)
        XCTAssertGreaterThan(pixel.greenComponent, 0.85, "Export must render the note, without a native-view placeholder")
        XCTAssertLessThan(pixel.blueComponent, 0.8, "The far-edge note must be rendered, not clipped to empty paper")
    }

    func testCanvasObjectsSurviveSaveExportAndImport() throws {
        let repository = repository()
        for kind in ["text", "ellipse", "rectangle", "diamond", "arrow", "line"] {
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(EaselItem(kind: .note))) as? [String: Any])
            payload["kind"] = kind
            payload["color"] = "cyan"
            payload["fontSize"] = 36
            payload["strokeWidth"] = 4
            payload["fillColor"] = "blue"
            payload["style"] = ["fontFamily": "handwritten", "textAlignment": "right", "stroke": "dashed", "fill": "crosshatch", "edges": "round", "roughness": 2, "opacity": 0.5]
            let item = try JSONDecoder().decode(EaselItem.self, from: JSONSerialization.data(withJSONObject: payload))
            var board = try repository.create(title: kind)
            board.items = [item]
            try repository.save(board)
            let copied = try repository.importBoard(JSONEncoder().encode(board))
            let reopened = EaselStore(profileID: repository.profileID, directory: repository.directory)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.kind.rawValue, kind)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.color, "cyan")
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.fontSize, 36)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.strokeWidth, 4)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.fillColor, "blue")
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.style?.fontFamily, .handwritten)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.style?.edges, .round)
            XCTAssertEqual(reopened.board(copied.id)?.items.first?.style?.opacity, 0.5)
        }
    }

    func testInvalidTextSizeCannotReplaceSavedBoard() throws {
        let repository = repository()
        let board = try repository.create()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(EaselItem(kind: .note))) as? [String: Any])
        payload["fontSize"] = 1000
        var changed = board
        changed.items = [try JSONDecoder().decode(EaselItem.self, from: JSONSerialization.data(withJSONObject: payload))]
        XCTAssertThrowsError(try repository.save(changed))
        XCTAssertEqual(repository.board(board.id), board)
    }

    func testFailedDeletionKeepsTheBoardAndUndoHistory() throws {
        let repository = repository()
        var board = try repository.create()
        board.title = "Keep me"
        try repository.save(board)
        try FileManager.default.removeItem(at: repository.directory)
        try Data().write(to: repository.directory)
        XCTAssertThrowsError(try repository.delete(board.id))
        XCTAssertEqual(repository.board(board.id)?.title, "Keep me")
        XCTAssertTrue(repository.canUndo(board.id))
    }

    func testOldItemsDecodeWithoutTextSize() throws {
        let data = try JSONEncoder().encode(EaselItem(kind: .note, text: "Existing note"))
        let item = try JSONDecoder().decode(EaselItem.self, from: data)
        XCTAssertEqual(item.text, "Existing note")
        XCTAssertNil(item.fontSize)
        XCTAssertNil(item.strokeWidth)
        XCTAssertNil(item.fillColor)
        XCTAssertNil(item.style)
    }

    func testDrawingToolsKeepTheDraggedPositionInsteadOfViewportInsertionPoint() {
        let session = EaselSession(repository()); session.create()
        session.insertionPoint = CGPoint(x: 80, y: 140)
        for kind in [EaselItem.Kind.drawing, .text, .ellipse, .rectangle, .arrow] {
            let item = EaselItem(kind: kind, color: "cyan", x: 450, y: 320, width: 200, height: 120)
            XCTAssertTrue(session.add(item))
            XCTAssertEqual(session.board?.items.last?.x, 450, "\(kind) must stay where it was drawn")
            XCTAssertEqual(session.board?.items.last?.y, 320)
        }
    }

    func testObjectMovementUsesScreenTranslationAtEveryZoom() {
        let item = EaselItem(kind: .rectangle, x: 520, y: 360)
        for zoom in [0.5, 1.0, 2.0] {
            let moved = EaselItemLayout.moved(item, translation: CGSize(width: 100, height: 50), zoom: zoom)
            XCTAssertEqual(moved.x, 520 + 100 / zoom)
            XCTAssertEqual(moved.y, 360 + 50 / zoom)
        }
    }

    func testEveryResizeCornerKeepsTheOppositeCornerAnchored() {
        let item = EaselItem(kind: .text, x: 200, y: 200, width: 300, height: 160)
        for corner in EaselItemLayout.Corner.allCases {
            let resized = EaselItemLayout.resized(item, corner: corner, translation: CGSize(width: 40, height: 20), zoom: 1)
            XCTAssertEqual(corner.leading ? resized.x + resized.width : resized.x, corner.leading ? 500 : 200)
            XCTAssertEqual(corner.top ? resized.y + resized.height : resized.y, corner.top ? 360 : 200)
            XCTAssertEqual(resized.width, corner.leading ? 260 : 340)
            XCTAssertEqual(resized.height, corner.top ? 140 : 180)
        }
    }

    func testTextToolUsesTheDraggedBoxAndKeepsItOnCanvas() throws {
        let item = try XCTUnwrap(EaselItemLayout.created(kind: .text, color: "ink", points: [EaselPoint(x: 750, y: 400), EaselPoint(x: 350, y: 180)]))
        XCTAssertEqual(item.x, 350)
        XCTAssertEqual(item.y, 180)
        XCTAssertEqual(item.width, 400)
        XCTAssertEqual(item.height, 220)
        XCTAssertEqual(item.fontSize, 20)
        try EaselStore.validate(EaselBoard(items: [item]))
    }

    func testResizeClampsAtCanvasEdgesAndScalesArrowPoints() throws {
        let item = EaselItem(kind: .arrow, points: [EaselPoint(x: 0, y: 120), EaselPoint(x: 300, y: 0)], x: 100, y: 100, width: 300, height: 120)
        let resized = EaselItemLayout.resized(item, corner: .topLeading, translation: CGSize(width: -500, height: -500), zoom: 1)
        XCTAssertEqual(resized.x, 0)
        XCTAssertEqual(resized.y, 0)
        XCTAssertEqual(resized.width, 400)
        XCTAssertEqual(resized.height, 220)
        XCTAssertEqual(resized.points.last?.x, 400)
        XCTAssertEqual(resized.points.first?.y, 220)
        try EaselStore.validate(EaselBoard(items: [resized]))
    }

    func testObjectSurfaceAcceptsInteriorHitsButEditingTextKeepsItsEditor() {
        let view = EaselPointerView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        XCTAssertTrue(view.hitTest(NSPoint(x: 150, y: 80)) === view)
        view.editing = true
        XCTAssertNil(view.hitTest(NSPoint(x: 150, y: 80)))
        view.selected = true
        XCTAssertTrue(view.hitTest(NSPoint(x: 4, y: 80)) === view)
        XCTAssertTrue(view.hitTest(NSPoint(x: 8, y: 8)) === view)
    }

    func testSingleClickSelectsAndOnlyDoubleClickEdits() throws {
        let view = EaselPointerView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        var selections = 0, edits = 0
        view.select = { selections += 1 }
        view.edit = { edits += 1 }
        func event(_ count: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 150, y: 80),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        view.mouseDown(with: try event(1))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(edits, 0)
        view.mouseDown(with: try event(2))
        XCTAssertEqual(selections, 2)
        XCTAssertEqual(edits, 1)
    }

    func testInvalidShapeStyleCannotReplaceSavedBoard() throws {
        let repository = repository()
        let board = try repository.create()
        for item in [EaselItem(kind: .rectangle, strokeWidth: .nan), EaselItem(kind: .rectangle, strokeWidth: 100), EaselItem(kind: .rectangle, fillColor: "invalid")] {
            var changed = board; changed.items = [item]
            XCTAssertThrowsError(try repository.save(changed))
            XCTAssertEqual(repository.board(board.id), board)
        }
    }

    func testPointerDragUsesWindowCoordinatesAndCommitsOnce() throws {
        let view = EaselPointerView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        var updates: [CGSize] = [], commits: [CGSize] = []
        var edits = 0
        view.edit = { edits += 1 }
        view.drag = { delta, corner, finished in
            XCTAssertNil(corner)
            if finished { commits.append(delta) } else { updates.append(delta) }
        }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 100, 100))
        view.mouseDragged(with: try event(.leftMouseDragged, 101, 99))
        XCTAssertTrue(updates.isEmpty)
        view.mouseDragged(with: try event(.leftMouseDragged, 130, 60))
        view.mouseUp(with: try event(.leftMouseUp, 130, 60))
        XCTAssertEqual(updates, [CGSize(width: 30, height: 40)])
        XCTAssertEqual(commits, [CGSize(width: 30, height: 40)])
        XCTAssertEqual(edits, 0)
    }

    func testCaptureAndLinkControlsRemainClickableThroughThePointerSurface() {
        let view = EaselPointerView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        view.footer = true
        XCTAssertTrue(view.hitTest(NSPoint(x: 150, y: 80)) === view)
        XCTAssertNil(view.hitTest(view.convert(NSPoint(x: 150, y: 140), to: nil)))
        view.live = true
        XCTAssertNil(view.hitTest(NSPoint(x: 150, y: 80)))
        view.selected = true
        XCTAssertTrue(view.hitTest(NSPoint(x: 4, y: 80)) === view)
    }

    func testFractionalResizeKeepsBoundaryPointsValid() throws {
        let width = 2292.1306576537336
        let item = EaselItem(kind: .line, points: [EaselPoint(x: width, y: 100)], x: 0, y: 0, width: width, height: 100)
        let resized = EaselItemLayout.resized(item, corner: .bottomTrailing,
            translation: CGSize(width: 3999.548176939395 - width, height: 0), zoom: 1)
        try EaselStore.validate(EaselBoard(items: [resized]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(resized.points.first?.x), resized.width)
    }

    func testExcalidrawHandwrittenFontIsBundledAndRegistersWithCoreText() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(EaselTypography.fontURL).path))
        _ = EaselTypography.font(.handwritten, size: 28)
        let font = try XCTUnwrap(NSFont(name: "Excalifont-Regular", size: 28))
        XCTAssertEqual(font.familyName, "Excalifont")
        XCTAssertNotNil(NSFont(name: "NunitoExtraLight-Medium", size: 20))
        XCTAssertNotNil(NSFont(name: "ComicShanns-Regular", size: 20))
    }

    func testInvalidOpacityAndRoughnessDoNotReplaceTheSavedBoard() throws {
        let repository = repository()
        let board = try repository.create()
        // Validate model styles before they reach JSON serialization or publication.
        for style in [EaselObjectStyle(roughness: .nan), EaselObjectStyle(roughness: 3), EaselObjectStyle(opacity: 1.1), EaselObjectStyle(opacity: -1)] {
            var changed = board; changed.items = [EaselItem(kind: .rectangle, style: style)]
            XCTAssertThrowsError(try repository.save(changed))
            XCTAssertEqual(repository.board(board.id), board)
        }
    }

    func testCustomColorsValidateAndSurviveImport() throws {
        let repository = repository()
        let board = EaselBoard(items: [EaselItem(kind: .rectangle, color: "#123ABC", fillColor: "#abcdef")])
        let imported = try repository.importBoard(JSONEncoder().encode(board))
        XCTAssertEqual(imported.items.first?.color, "#123ABC")
        XCTAssertEqual(imported.items.first?.fillColor, "#abcdef")
        for value in ["#123", "#12345Z", "unknown"] { XCTAssertFalse(EaselItem.validColor(value)) }
    }

}
