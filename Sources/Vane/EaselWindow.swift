import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor final class EaselSession: ObservableObject {
    let repository: EaselStore
    @Published var selected: UUID?
    @Published var message: String?
    @Published var capturing = false
    @Published var liveItems: Set<UUID> = []
    var insertionPoint = CGPoint(x: 120, y: 140)
    init(_ repository: EaselStore) { self.repository = repository; selected = repository.boards.first?.id }
    var board: EaselBoard? { selected.flatMap(repository.board) }
    @discardableResult func perform(_ work: () throws -> Void) -> Bool {
        do { try work(); return true } catch { message = error.localizedDescription; return false }
    }
    func create() { perform { selected = try repository.create().id } }
    @discardableResult func edit(_ change: (inout EaselBoard) -> Void) -> Bool {
        guard var board else { return false }
        change(&board)
        let saved = perform { try repository.save(board) }
        if saved { pruneLiveItems() }
        return saved
    }
    func placed(_ item: EaselItem, in board: EaselBoard) -> EaselItem {
        guard ![.drawing, .text, .ellipse, .rectangle, .diamond, .arrow, .line].contains(item.kind) else { return item }
        var item = item
        let stagger = Double(board.items.count % 6) * 24
        item.x = min(max(0, insertionPoint.x + stagger), EaselStore.canvasWidth - item.width)
        item.y = min(max(0, insertionPoint.y + stagger), EaselStore.canvasHeight - item.height)
        return item
    }
    @discardableResult func add(_ item: EaselItem) -> Bool { edit { $0.items.append(placed(item, in: $0)) } }
    func pruneLiveItems() {
        liveItems.formIntersection(Set((board?.items ?? []).filter { $0.kind == .image && EaselItem.webURL($0.source) != nil }.map(\.id)))
    }
    func toggleLive(_ id: UUID) {
        guard board?.items.contains(where: { $0.id == id && $0.kind == .image && EaselItem.webURL($0.source) != nil }) == true else { return }
        if liveItems.contains(id) { liveItems.remove(id) }
        else if liveItems.count < 4 { liveItems.insert(id) }
        else { message = "Pause a live view before opening another. Up to four can run at once." }
    }
    func undo() { if let selected { perform { try repository.undo(selected) }; pruneLiveItems() } }
    func redo() { if let selected { perform { try repository.redo(selected) }; pruneLiveItems() } }
    func paste() {
        let clipboard = NSPasteboard.general
        if let image = NSImage(pasteboard: clipboard) {
            perform { add(try EaselWindow.imageItem(image)) }
        } else if let text = clipboard.string(forType: .string) {
            let url = EaselItem.webURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
            add(EaselItem(kind: url == nil ? .note : .link, text: url?.host ?? String(text.prefix(100_000)), source: url?.absoluteString ?? ""))
        }
    }
}

/// Browser entry points and image/export utilities shared by Easel tabs.
@MainActor enum EaselWindow {
    private static var capturing: Set<UUID> = []

    @discardableResult static func show(profileID: UUID, boardID: UUID? = nil, create: Bool = false,
                                       in origin: TabStore? = nil) -> EaselSession? {
        guard let store = origin ?? BookmarkManager.browserWindow(for: profileID),
              store.profileID == profileID, !store.isPrivate, !store.isLittle,
              let tab = store.openEasel(boardID, create: create) else { return nil }
        store.window?.makeKeyAndOrderFront(nil)
        return tab.easelSession
    }

    static var focused: EaselSession? { Windows.current?.active?.easelSession }
    static var canOpen: Bool { Windows.current.map { !$0.isPrivate && !$0.isLittle } ?? false }
    static func open(in store: TabStore?, create: Bool = false) {
        guard let store, !store.isPrivate, !store.isLittle else { return }
        if create { store.openEasel(create: true) }
        else { Library.open(.easels, in: store) }
    }
    static func canCapture(in store: TabStore?) -> Bool {
        guard let store, !store.isPrivate, store.window?.isKeyWindow == true,
              let source = store.active?.existingWeb?.url, store.active?.easelID == nil else { return false }
        return EaselItem.webURL(source.absoluteString) != nil
    }
    static func forget(_ profileID: UUID) {
        for tab in TabStore.all.filter({ $0.profileID == profileID }).flatMap(\.everyTab) {
            tab.easelSession?.liveItems.removeAll()
        }
    }

    /// Save first, then reveal the board. The capture preview chooses its destination.
    @discardableResult static func addCapture(_ image: NSImage, title: String, source: String,
                                             to boardID: UUID?, in store: TabStore) -> Bool {
        guard !store.isPrivate, !store.isLittle, EaselItem.webURL(source) != nil else { return false }
        let repository = EaselStore.shared(profileID: store.profileID, directory: Store.directory)
        do {
            let item = try imageItem(image, title: title, source: source)
            var board: EaselBoard
            if let boardID {
                guard let existing = repository.board(boardID) else { throw EaselStore.Failure.missing }
                board = existing
            } else { board = try repository.create() }
            let session = store.tabs.first { $0.easelID == board.id }?.easelSession ?? EaselSession(repository)
            board.items.append(session.placed(item, in: board))
            try repository.save(board)
            return store.openEasel(board.id) != nil
        } catch {
            Toasts.show(error.localizedDescription)
            return false
        }
    }

    /// Capture the page's visible viewport, using its existing authenticated WebKit view.
    /// Freeze the URL and profile before the async snapshot; never save private content.
    static func capture(in store: TabStore?) {
        guard canCapture(in: store), let store, let tab = store.active,
              let web = tab.existingWeb, let source = web.url,
              EaselItem.webURL(source.absoluteString) != nil,
              capturing.insert(store.windowID).inserted else { return }
        let title = tab.title
        let repository = EaselStore.shared(profileID: store.profileID, directory: Store.directory)
        let recent = store.tabs.filter { $0.easelID.flatMap(repository.board) != nil }.max { $0.lastActive < $1.lastActive }?.easelID
        let targetID = recent ?? repository.boards.first?.id
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 1400
        web.takeSnapshot(with: configuration) { [weak store] image, error in
            Task { @MainActor in
                guard let store else { return }
                defer { capturing.remove(store.windowID) }
                // A navigation while WebKit was capturing must not label another page's pixels.
                guard web.url == source else { Toasts.show("The page changed during capture. Try again."); return }
                guard let image else { Toasts.show(error?.localizedDescription ?? "The page could not be captured."); return }
                addCapture(image, title: title, source: source.absoluteString, to: targetID, in: store)
            }
        }
    }

    static func png(for board: EaselBoard, profileID: UUID) throws -> Data {
        let width = min(EaselStore.canvasWidth, max(800, (board.items.map { $0.x + $0.width }.max() ?? 0) + 40))
        let height = min(EaselStore.canvasHeight, max(600, (board.items.map { $0.y + $0.height }.max() ?? 0) + 40))
        let scale = min(1, 4096 / width, 4096 / height)
        let renderer = ImageRenderer(content: EaselCanvas(items: board.items, selected: nil, drawing: false,
                                    profileID: profileID, liveItems: [], toggleLive: { _ in }, stroke: [], zoom: 1, select: { _ in }, edit: { _ in }, change: { _ in true }, draw: { _, _ in }, interactive: false)
                                    .frame(width: width, height: height, alignment: .topLeading).clipped()
                                    .scaleEffect(scale, anchor: .topLeading)
                                    .frame(width: width * scale, height: height * scale, alignment: .topLeading).clipped())
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw EaselStore.Failure.invalid }
        return png
    }

    static func imageItem(_ image: NSImage, title: String = "Image", source: String = "") throws -> EaselItem {
        guard image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width * image.size.height <= 32_000_000 else { throw EaselStore.Failure.tooLarge }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let resized = NSImage(size: NSSize(width: image.size.width * scale, height: image.size.height * scale))
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: resized.size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= EaselStore.imageLimit
        else { throw EaselStore.Failure.tooLarge }
        let width = min(520, max(120, image.size.width))
        let height = min(1600, max(100, width * image.size.height / image.size.width + 44))
        return EaselItem(kind: .image, text: title, source: source, image: png, width: width, height: height)
    }
}

/// Standard Edit menu commands still reach text editors first, then the board's responder.
@MainActor final class EaselHostingView: NSHostingView<EaselWorkspace>, NSMenuItemValidation {
    var session: EaselSession { rootView.session }
    required init(rootView: EaselWorkspace) {
        super.init(rootView: rootView)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    static func find(_ session: EaselSession, in view: NSView?) -> EaselHostingView? {
        guard let view else { return nil }
        if let host = view as? EaselHostingView, host.session === session { return host }
        return view.subviews.lazy.compactMap { find(session, in: $0) }.first
    }
    @objc func undo(_ sender: Any?) { session.undo() }
    @objc func redo(_ sender: Any?) { session.redo() }
    @objc func paste(_ sender: Any?) { session.paste() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = session.selected else { return false }
        if item.action == #selector(undo(_:)) { return session.repository.canUndo(id) }
        if item.action == #selector(redo(_:)) { return session.repository.canRedo(id) }
        return true
    }
}

struct EaselWorkspace: View {
    @ObservedObject var session: EaselSession
    @ObservedObject var repository: EaselStore
    let browser: TabStore
    init(session: EaselSession, browser: TabStore) {
        self.session = session; repository = session.repository; self.browser = browser
    }
    var body: some View {
        Group {
            if let board = session.board {
                EaselEditor(session: session, repository: repository, boardID: board.id,
                            openBoard: { browser.openEasel($0) }).id(board.id)
            } else {
                ContentUnavailableView {
                    Label("Easel unavailable", systemImage: "paintpalette")
                } description: {
                    Text("This board may have been deleted. Your other saved Easels are in Library.")
                } actions: {
                    Button("Open Easels") { Library.open(.easels, in: browser) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard EaselItem.webURL(url.absoluteString) != nil else { return .discarded }
            browser.newTab(url)
            return .handled
        })
        .overlay(alignment: .bottom) {
            if let error = repository.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout)
                    Button("Retry") { repository.reload() }
                }.padding().background(.regularMaterial, in: .rect(cornerRadius: 10)).padding()
            }
        }
        .alert("Easel could not be updated", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK") { session.message = nil }
        } message: { Text(session.message ?? "") }
    }
}

private struct EaselEditor: View {
    @ObservedObject var session: EaselSession
    @ObservedObject var repository: EaselStore
    let boardID: UUID
    var openBoard: (UUID) -> Void = { _ in }
    @State private var selected: UUID?
    @State private var zoom = 1.0
    @State private var hand = false
    @State private var toolLocked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportSize = CGSize(width: 1200, height: 800)
    @State private var drawingStyle = EaselObjectStyle(fontFamily: .handwritten, fill: .hachure, edges: .round, roughness: 1)
    @State private var drawingFontSize = 20.0
    @State private var strokeWidth = 2.0
    @State private var fillColor: String?
    @State private var inlineEditing: UUID?
    @State private var editRequest = UUID()
    @State private var drawing = false
    @State private var drawingKind: EaselItem.Kind = .drawing
    @State private var drawingColor = "ink"
    @State private var stroke: [EaselPoint] = []
    @State private var editing: EaselItem?
    @State private var title = ""
    @State private var viewport = CGPoint.zero
    @FocusState private var canvasFocused: Bool
    private var board: EaselBoard { repository.board(boardID) ?? EaselBoard() }
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView([.horizontal, .vertical]) {
                EaselCanvas(items: board.items, selected: selected, drawing: drawing,
                            profileID: repository.profileID, liveItems: session.liveItems, toggleLive: session.toggleLive,
                            stroke: stroke, zoom: zoom, hand: hand, editRequest: editRequest, drawingKind: drawingKind, drawingColor: drawingColor, drawingStrokeWidth: strokeWidth, drawingFillColor: fillColor, drawingStyle: drawingStyle,
                            select: { selected = $0; canvasFocused = true },
                            edit: { editing = $0 }, change: { changeItem($0) },
                            textEditingChanged: { id, active in
                                if active { inlineEditing = id } else if inlineEditing == id { inlineEditing = nil }
                            },
                            draw: drawingGesture)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: EaselStore.canvasWidth * zoom, height: EaselStore.canvasHeight * zoom, alignment: .topLeading)
                .focusable().focusEffectDisabled().focused($canvasFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
            }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in geometry.contentOffset } action: { _, offset in
                viewport = offset
                session.insertionPoint = CGPoint(x: max(0, offset.x / zoom) + 80, y: max(0, offset.y / zoom) + 140)
            }
            .background(EaselColors.paper)
            ViewThatFits(in: .horizontal) {
                toolbar
                ScrollView(.horizontal) { toolbar }.scrollIndicators(.hidden).frame(height: 48)
            }.padding(.horizontal, 16).padding(.top, 16)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Untitled Easel", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .onChange(of: title) { session.edit { $0.title = String(title.prefix(200)) } }
                    .accessibilityLabel("Easel name")
                if drawing || selected != nil {
                    ScrollView(.vertical) { properties }.scrollIndicators(.hidden)
                        .frame(maxHeight: max(100, viewportSize.height - (viewportSize.width < 960 ? 200 : 130)))
                }
            }.frame(width: 190).padding(16).padding(.top, viewportSize.width < 960 ? 65 : 0)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 14) {
                Button { zoom = max(0.25, zoom - 0.25) } label: { Image(systemName: "minus") }.help("Zoom out")
                Button("\(Int(zoom * 100))%") { zoom = 1 }.frame(width: 44).help("Reset zoom")
                Button { zoom = min(2, zoom + 0.25) } label: { Image(systemName: "plus") }.help("Zoom in")
                Divider().frame(height: 22)
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!repository.canUndo(boardID)).help("Undo · ⌘Z")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!repository.canRedo(boardID)).help("Redo · ⇧⌘Z")
            }.buttonStyle(.plain).font(.system(size: 13)).padding(12)
                .background(EaselColors.panel, in: .rect(cornerRadius: 10)).padding(16)
        }
        .overlay(alignment: .bottomTrailing) {
            Label("Saved locally", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .animation(reduceMotion || Motion.reduced ? nil : .easeOut(duration: 0.12), value: drawing)
        .animation(reduceMotion || Motion.reduced ? nil : .easeOut(duration: 0.12), value: selected)
        .animation(reduceMotion || Motion.reduced ? nil : .easeOut(duration: 0.12), value: hand)
        .onAppear { title = board.title; session.insertionPoint = CGPoint(x: 120, y: 140) }
        .onChange(of: zoom) {
            session.insertionPoint = CGPoint(x: max(0, viewport.x / zoom) + 80, y: max(0, viewport.y / zoom) + 80)
        }
        .onChange(of: board.title) { title = board.title }
        .onChange(of: board.items) {
            session.pruneLiveItems()
        }
        .sheet(item: $editing) { item in
            EaselItemEditor(item: item) { updated in
                if board.items.contains(where: { $0.id == updated.id }) { return changeItem(updated) }
                let saved = session.add(updated)
                if saved { selected = updated.id }
                return saved
            }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 3) {
            tool("Keep tool active", "lock", active: toolLocked) { toolLocked.toggle(); canvasFocused = true }
            Divider().frame(height: 24).padding(.horizontal, 3)
            tool("Hand · H", "hand.draw", active: hand) { hand = true; drawing = false; selected = nil; canvasFocused = true }
            tool("Select · V / 1", "cursorarrow", active: !drawing && !hand, number: "1") { selectTool() }
            tool("Rectangle · R / 2", "square", active: drawing && drawingKind == .rectangle, number: "2") { chooseDrawing(.rectangle) }
            tool("Diamond · D / 3", "diamond", active: drawing && drawingKind == .diamond, number: "3") { chooseDrawing(.diamond) }
            tool("Ellipse · O / 4", "circle", active: drawing && drawingKind == .ellipse, number: "4") { chooseDrawing(.ellipse) }
            tool("Arrow · A / 5", "arrow.up.right", active: drawing && drawingKind == .arrow, number: "5") { chooseDrawing(.arrow) }
            tool("Line · L / 6", "line.diagonal", active: drawing && drawingKind == .line, number: "6") { chooseDrawing(.line) }
            tool("Draw · P / 7", "pencil.tip", active: drawing && drawingKind == .drawing, number: "7") { chooseDrawing(.drawing) }
            tool("Text · T / 8", "textformat", active: drawing && drawingKind == .text, number: "8") { chooseDrawing(.text) }
            tool("Image · 9", "photo", number: "9") { selectTool(); importImages() }
            Divider().frame(height: 24).padding(.horizontal, 3)
            Menu {
                Button("Add Note") { editing = EaselItem(kind: .note) }
                Button("Add Link") { editing = EaselItem(kind: .link) }
                Button("Paste") { paste() }
                Divider()
                Button("Duplicate Easel") {
                    session.perform { openBoard(try repository.importBoard(JSONEncoder().encode(board)).id) }
                }
                Button("Export PNG…") { exportPNG() }
                Button("Export Editable Easel…") { exportBoard() }
                Button("Delete Easel…", role: .destructive) { deleteBoard() }
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).help("More Easel actions")
                .accessibilityLabel("More Easel actions")
        }.padding(6).background(EaselColors.panel, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07), lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
    @ViewBuilder private var properties: some View {
        if drawing || selected != nil {
            let item = board.items.first { $0.id == selected }
            let kind = drawing ? drawingKind : item?.kind
            if kind != .image && kind != .link {
                VStack(alignment: .leading, spacing: 16) {
                    Text(kind == .note ? "Background" : "Stroke").font(.caption)
                    EaselPalette(color: item?.color ?? drawingColor, choose: { color in
                        if var item { item.color = color; _ = changeItem(item) } else { drawingColor = color }
                    }, colors: kind == .note ? ["yellow", "pink", "blue", "green"] : ["ink", "red", "green", "blue", "orange"], fill: kind == .note, allowsTransparent: false)
                    if kind == .rectangle || kind == .diamond || kind == .ellipse {
                        Text("Background").font(.caption)
                        EaselPalette(color: (item == nil ? fillColor : item?.fillColor) ?? "none", choose: { color in
                            let value: String? = color == "none" ? nil : color
                            if var item { item.fillColor = value; _ = changeItem(item) } else { fillColor = value }
                        }, colors: ["none", "pink", "green", "blue", "yellow"], fill: true)
                    }
                    styleControls(item, kind: kind)
                    if item != nil {
                        Divider()
                        HStack(spacing: 20) {
                            Button { duplicateItem() } label: { Image(systemName: "square.on.square") }.help("Duplicate · ⌘D")
                            Button { deleteItem() } label: { Image(systemName: "trash") }.help("Delete")
                        }.buttonStyle(.plain)
                    }
                }.padding(12).background { RoundedRectangle(cornerRadius: 10).fill(EaselColors.panel) }
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07), lineWidth: 1))
            }
        }
    }
    private func styleControls(_ item: EaselItem?, kind: EaselItem.Kind?) -> EaselStylePanel {
        let layerAction: ((Int) -> Void)? = item == nil ? nil : { position in layerItem(position) }
        return EaselStylePanel(style: item?.style ?? (item == nil ? drawingStyle : EaselObjectStyle()),
                                    shape: kind != .text && kind != .note,
                                    text: kind == .text || kind == .note || item?.text.isEmpty == false,
                                    closedShape: kind == .rectangle || kind == .ellipse || kind == .diamond,
                                    supportsEdges: kind == .rectangle || kind == .diamond,
                                    filled: (item == nil ? fillColor : item?.fillColor) != nil,
                                    fontSize: item?.fontSize ?? drawingFontSize,
                                    strokeWidth: item?.strokeWidth ?? (item == nil ? strokeWidth : 3),
                                    change: { style in
                        if var item { item.style = style; _ = changeItem(item) } else { drawingStyle = style }
                    }, changeFont: { size in
                        if var item { item.fontSize = size; _ = changeItem(item) } else { drawingFontSize = size }
                    }, changeStroke: { width in
                        if var item { item.strokeWidth = width; _ = changeItem(item) } else { strokeWidth = width }
                    }, layer: layerAction)
    }
    private func layerItem(_ position: Int) {
        guard let selected else { return }
        _ = session.edit { board in
            guard let index = board.items.firstIndex(where: { $0.id == selected }) else { return }
            let target = position == 0 ? 0 : position == 1 ? max(0, index - 1) : position == 2 ? min(board.items.count - 1, index + 1) : board.items.count - 1
            guard index != target else { return }
            let item = board.items.remove(at: index); board.items.insert(item, at: target)
        }
    }
    private func selectTool() { hand = false; drawing = false; canvasFocused = true }
    private func duplicateItem() {
        guard var item = board.items.first(where: { $0.id == selected }) else { return }
        item.id = UUID()
        item = EaselItemLayout.moved(item, translation: CGSize(width: 24, height: 24), zoom: 1)
        // Duplicates keep their relative canvas position, including notes and images.
        if session.edit({ $0.items.append(item) }) { selected = item.id }
    }
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard inlineEditing == nil else { return .ignored }
        if press.modifiers.contains(.command) {
            if press.characters == "d" { duplicateItem(); return .handled }
            return .ignored
        }
        if press.key == .escape { selected = nil; selectTool(); return .handled }
        if press.key == .delete || press.key == .deleteForward {
            guard selected != nil else { return .ignored }; deleteItem(); return .handled
        }
        if press.key == .return, selected != nil { editRequest = UUID(); return .handled }
        if [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(press.key), let item = board.items.first(where: { $0.id == selected }) {
            let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
            let dx = press.key == .leftArrow ? -step : press.key == .rightArrow ? step : 0
            let dy = press.key == .upArrow ? -step : press.key == .downArrow ? step : 0
            _ = changeItem(EaselItemLayout.moved(item, translation: CGSize(width: dx, height: dy), zoom: 1)); return .handled
        }
        switch press.characters.lowercased() {
        case "1", "v": selectTool()
        case "h": hand = true; drawing = false; selected = nil
        case "2", "r": chooseDrawing(.rectangle)
        case "3", "d": chooseDrawing(.diamond)
        case "4", "o": chooseDrawing(.ellipse)
        case "5", "a": chooseDrawing(.arrow)
        case "6", "l": chooseDrawing(.line)
        case "7", "p": chooseDrawing(.drawing)
        case "8", "t": chooseDrawing(.text)
        case "9": selectTool(); importImages()
        default: return .ignored
        }
        return .handled
    }
    private func chooseDrawing(_ kind: EaselItem.Kind) { hand = false; drawingKind = kind; drawing = true; selected = nil; canvasFocused = true }
    private func tool(_ title: String, _ icon: String, active: Bool = false, number: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 36, height: 36)
                .overlay(alignment: .bottomTrailing) {
                    if let number { Text(number).font(.system(size: 8)).foregroundStyle(.secondary).padding(3) }
                }
                .background(active ? EaselColors.selection.opacity(0.18) : .clear, in: .rect(cornerRadius: 7))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }
    @discardableResult private func changeItem(_ item: EaselItem) -> Bool {
        session.edit { board in
            if let index = board.items.firstIndex(where: { $0.id == item.id }) { board.items[index] = item }
        }
    }
    private func deleteItem() {
        guard let selected else { return }
        session.edit { $0.items.removeAll { $0.id == selected } }
        self.selected = nil
    }
    private func drawingGesture(_ point: CGPoint?, _ finished: Bool) {
        if let point, stroke.count < 5000 {
            stroke.append(EaselPoint(x: min(max(0, point.x), EaselStore.canvasWidth), y: min(max(0, point.y), EaselStore.canvasHeight)))
        }
        guard finished else { return }
        defer { stroke = [] }
        guard var item = EaselItemLayout.created(kind: drawingKind, color: drawingColor, points: stroke) else { return }
        item.strokeWidth = strokeWidth; item.fillColor = fillColor; item.style = drawingStyle
        if item.kind == .text { item.fontSize = drawingFontSize }
        if [.rectangle, .ellipse, .diamond].contains(item.kind) { item.style?.textAlignment = .center }
        if session.add(item) { selected = toolLocked && item.kind != .text ? nil : item.id; drawing = toolLocked && item.kind != .text }
    }
    private func importImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            session.perform {
                guard let image = NSImage(contentsOf: url) else { throw EaselStore.Failure.invalid }
                session.add(try EaselWindow.imageItem(image, title: url.lastPathComponent))
            }
        }
    }
    private func paste() { session.paste() }
    private func exportBoard() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Easel.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.perform { try JSONEncoder().encode(board).write(to: url, options: .atomic) }
    }
    private func exportPNG() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Easel.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.perform { try EaselWindow.png(for: board, profileID: repository.profileID).write(to: url, options: .atomic) }
    }
    private func deleteBoard() {
        let alert = NSAlert(); alert.messageText = "Delete this Easel?"
        alert.informativeText = "Its notes, drawings, and images will be removed. Export a copy first if you want to keep it."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.perform { try repository.delete(boardID) }
    }
}

enum EaselColors {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let selection = Color(red: 0.42, green: 0.36, blue: 0.86)
    static let paper = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(red: 0.19, green: 0.22, blue: 0.23)
    static let palette = ["ink", "yellow", "orange", "red", "green", "white", "gray", "pink", "cyan", "blue", "purple"]
    static func object(_ color: String) -> Color {
        switch color {
        case "yellow": .yellow
        case "orange": Color(red: 0.94, green: 0.55, blue: 0)
        case "red": Color(red: 0.88, green: 0.19, blue: 0.19)
        case "green": Color(red: 0.18, green: 0.62, blue: 0.27)
        case "white": .white
        case "gray": .gray
        case "pink": .pink
        case "cyan": .cyan
        case "blue": Color(red: 0.09, green: 0.44, blue: 0.76)
        case "purple": .purple
        default: Color(hex: color) ?? Color.primary
        }
    }
    static func fill(_ color: String) -> Color {
        switch color {
        case "pink": Color(red: 1, green: 0.79, blue: 0.79)
        case "green": Color(red: 0.70, green: 0.95, blue: 0.73)
        case "blue": Color(red: 0.65, green: 0.85, blue: 1)
        case "yellow": Color(red: 1, green: 0.93, blue: 0.6)
        default: object(color)
        }
    }
    @MainActor static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "ink" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func card(_ color: String) -> Color {
        switch color {
        case "pink": Color(red: 1, green: 0.84, blue: 0.86)
        case "blue": Color(red: 0.82, green: 0.9, blue: 0.98)
        case "green": Color(red: 0.84, green: 0.92, blue: 0.81)
        case "yellow": Color(red: 1, green: 0.93, blue: 0.68)
        default: fill(color)
        }
    }
}

private struct EaselCanvas: View {
    let items: [EaselItem]
    let selected: UUID?
    let drawing: Bool
    let profileID: UUID
    let liveItems: Set<UUID>
    let toggleLive: (UUID) -> Void
    let stroke: [EaselPoint]
    let zoom: Double
    var hand = false
    var editRequest: UUID?
    var drawingKind: EaselItem.Kind = .drawing
    var drawingColor = "ink"
    var drawingStrokeWidth = 3.0
    var drawingFillColor: String?
    var drawingStyle = EaselObjectStyle()
    let select: (UUID?) -> Void
    let edit: (EaselItem) -> Void
    let change: (EaselItem) -> Bool
    var textEditingChanged: (UUID, Bool) -> Void = { _, _ in }
    let draw: (CGPoint?, Bool) -> Void
    var interactive = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            EaselColors.paper.onTapGesture { select(nil) }
            ForEach(items) { item in
                EaselCard(item: item, selected: selected == item.id, profileID: profileID,
                          live: liveItems.contains(item.id), zoom: zoom, editRequest: editRequest, toggleLive: { toggleLive(item.id) }, select: { select(item.id) }, edit: { edit(item) }, change: change, textEditingChanged: { textEditingChanged(item.id, $0) }, interactive: interactive)
                    .offset(x: item.x, y: item.y)
                    .allowsHitTesting(!drawing && !hand)
            }
            if hand { EaselPan() }
            if drawing {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("easel-canvas"))
                        .onChanged { draw($0.location, false) }.onEnded { draw($0.location, true) })
                EaselDrawingPreview(points: stroke, kind: drawingKind, color: drawingColor, strokeWidth: drawingStrokeWidth, fillColor: drawingFillColor, style: drawingStyle)
                    .allowsHitTesting(false)
            }
            if items.isEmpty && !drawing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A space for your ideas").font(.system(size: 24, weight: .semibold))
                    Text("Add text, add an image, or draw something.\nCollect a page with File → Capture Page to Easel.")
                        .font(.body).foregroundStyle(.secondary)
                }.foregroundStyle(.secondary).padding(.horizontal, 80).padding(.top, 180).allowsHitTesting(false)
            }
        }
        .frame(width: EaselStore.canvasWidth, height: EaselStore.canvasHeight)
        .coordinateSpace(name: "easel-canvas")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Easel canvas")
    }
}

private struct EaselCard: View {
    let item: EaselItem
    let selected: Bool
    let profileID: UUID
    let live: Bool
    let zoom: Double
    let editRequest: UUID?
    let toggleLive: () -> Void
    let select: () -> Void
    let edit: () -> Void
    let change: (EaselItem) -> Bool
    let textEditingChanged: (Bool) -> Void
    var interactive = true
    @State private var textEditing = false
    @State private var textDraft = ""
    @FocusState private var textFocused: Bool
    @State private var movement = CGSize.zero
    @State private var resizing = CGSize.zero
    @State private var resizeCorner = EaselItemLayout.Corner.bottomTrailing
    private var layout: EaselItem { EaselItemLayout.resized(item, corner: resizeCorner, translation: resizing, zoom: zoom) }
    private var arrangedContent: some View {
        content
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .background([.drawing, .text, .ellipse, .rectangle, .diamond, .arrow, .line].contains(item.kind) ? Color.clear : (item.kind == .note ? EaselColors.card(item.color) : .white),
                        in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .opacity(item.style?.opacity ?? 1)
            .contentShape(Rectangle())
            .overlay {
                if interactive {
                    EaselPointer(selected: selected, editing: textEditing, footer: item.kind == .image || item.kind == .link, live: live,
                                 select: select, edit: editContent, drag: pointerDrag)
                }
            }
    }
    private var selectionContent: some View {
        arrangedContent
            .overlay {
                if selected {
                    Rectangle().stroke(EaselColors.selection, lineWidth: 1).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) { if selected { handle(.topLeading) } }
            .overlay(alignment: .topTrailing) { if selected { handle(.topTrailing) } }
            .overlay(alignment: .bottomLeading) { if selected { handle(.bottomLeading) } }
            .overlay(alignment: .bottomTrailing) { if selected { handle(.bottomTrailing) } }
    }
    private var interactiveContent: some View {
        selectionContent
            .onAppear {
                if selected && item.kind == .text && item.text.isEmpty { editContent() }
            }
            .onChange(of: selected) { if !selected { saveText() } }
            .onChange(of: editRequest) { if selected && editRequest != nil { editContent() } }
            .onDisappear { saveText(); textEditingChanged(false) }
            .contextMenu {
                if [.text, .note, .link, .image, .rectangle, .ellipse, .diamond].contains(item.kind) {
                    Button(item.kind == .text ? "Edit Text" : "Edit…") { editContent() }
                }
                if item.kind == .image && !item.source.isEmpty {
                    Button(live ? "Pause Live View" : "View Source Page Live") { toggleLive() }
                }
            }
    }
    var body: some View {
        interactiveContent
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.text.isEmpty ? item.kind.rawValue.capitalized : item.text)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Edit") { editContent() }
            .accessibilityAction(named: "Move left") { move(dx: -24, dy: 0) }
            .accessibilityAction(named: "Move right") { move(dx: 24, dy: 0) }
            .accessibilityAction(named: "Move up") { move(dx: 0, dy: -24) }
            .accessibilityAction(named: "Move down") { move(dx: 0, dy: 24) }
            .offset(x: layout.x - item.x + movement.width / zoom, y: layout.y - item.y + movement.height / zoom)
    }
    private func handle(_ corner: EaselItemLayout.Corner) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(EaselColors.paper).frame(width: 8, height: 8)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(EaselColors.selection, lineWidth: 1.5))
            .frame(width: 24, height: 24).allowsHitTesting(false)
            .accessibilityLabel("Resize \(corner.rawValue) corner")
    }
    private func pointerDrag(_ translation: CGSize, _ corner: EaselItemLayout.Corner?, _ finished: Bool) {
        if let corner {
            resizeCorner = corner
            resizing = translation
            if finished { _ = change(EaselItemLayout.resized(item, corner: corner, translation: translation, zoom: zoom)) }
        } else {
            movement = translation
            if finished { _ = change(EaselItemLayout.moved(item, translation: translation, zoom: zoom)) }
        }
        if finished { movement = .zero; resizing = .zero }
    }
    private func editContent() {
        select()
        switch item.kind {
        case .text, .rectangle, .ellipse, .diamond:
            guard !textEditing else { return }
            textDraft = item.text; textEditing = true; textEditingChanged(true)
            DispatchQueue.main.async { textFocused = true }
        case .note, .link, .image: edit()
        default: break
        }
    }
    private func saveText() {
        guard textEditing else { return }
        var updated = item; updated.text = String(textDraft.prefix(100_000))
        if change(updated) { textEditing = false; textEditingChanged(false) }
    }
    private func move(dx: Double, dy: Double) {
        var moved = item
        moved.x = min(max(0, item.x + dx), EaselStore.canvasWidth - item.width)
        moved.y = min(max(0, item.y + dy), EaselStore.canvasHeight - item.height)
        _ = change(moved); select()
    }
    @ViewBuilder private var content: some View {
        switch item.kind {
        case .note:
            Text(item.text.isEmpty ? "Double-click to write a note" : item.text)
                .font(EaselTypography.font(item.style?.fontFamily ?? .normal, size: item.fontSize ?? 18)).foregroundStyle(EaselColors.ink)
                .multilineTextAlignment(item.style?.alignment ?? .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textAlignment(centered: false)).padding(18)
        case .link:
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "link").font(.title2)
                Text(item.text.isEmpty ? item.source : item.text).font(.headline).lineLimit(3)
                Text(item.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if let url = EaselItem.webURL(item.source) { Link("Open source ↗", destination: url).font(.callout) }
            }.foregroundStyle(EaselColors.ink).padding(18)
        case .image:
            VStack(spacing: 0) {
                if live, let url = EaselItem.webURL(item.source) {
                    EaselLiveView(url: url, profileID: profileID)
                } else if let data = item.image, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Image(systemName: "photo.badge.exclamationmark").frame(maxWidth: .infinity, maxHeight: .infinity) }
                HStack {
                    Text(item.text).font(.caption).lineLimit(1)
                    Spacer()
                    if let url = EaselItem.webURL(item.source) {
                        Button(action: toggleLive) { Image(systemName: live ? "pause.circle.fill" : "play.circle") }
                            .buttonStyle(.plain).help(live ? "Pause live view" : "View source page live")
                            .accessibilityLabel(live ? "Pause live view" : "View source page live")
                        Link(destination: url) { Image(systemName: "arrow.up.right") }.help("Open source page")
                    }
                }.foregroundStyle(EaselColors.ink).padding(12)
            }
        case .text:
            inlineText(centered: false)
        case .ellipse, .rectangle, .diamond, .arrow, .line:
            ZStack {
                EaselShape(kind: item.kind, points: item.points, color: item.color, width: item.width, height: item.height,
                           strokeWidth: item.strokeWidth ?? 3, fillColor: item.fillColor, style: item.style ?? EaselObjectStyle()).padding(4)
                if !item.text.isEmpty || textEditing { inlineText(centered: true) }
            }
        case .drawing: EaselStroke(points: item.points, width: item.width, height: item.height, color: item.color, strokeWidth: item.strokeWidth ?? 3, style: item.style ?? EaselObjectStyle())
        }

    }
    private func inlineText(centered: Bool) -> some View {
        Group {
            if textEditing {
                TextField("Start typing to enter text", text: $textDraft, axis: .vertical)
                    .textFieldStyle(.plain).focused($textFocused)
                    .onKeyPress(.escape) { saveText(); return .handled }
                    .onChange(of: textFocused) { if !textFocused { saveText() } }
            } else {
                Text(item.text.isEmpty ? "Start typing to enter text" : item.text)
            }
        }.font(EaselTypography.font(item.style?.fontFamily ?? .normal, size: item.fontSize ?? (centered ? 20 : 28)))
            .foregroundStyle(EaselColors.object(item.color))
            .multilineTextAlignment(item.style?.alignment ?? (centered ? .center : .leading))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textAlignment(centered: centered)).padding(12)
    }

    private func textAlignment(centered: Bool) -> Alignment {
        let align = item.style?.textAlignment ?? (centered ? .center : .left)
        if centered { return align == .left ? .leading : align == .right ? .trailing : .center }
        return align == .left ? .topLeading : align == .right ? .topTrailing : .top
    }
}

struct EaselStroke: View {
    let points: [EaselPoint]
    let width: Double
    let height: Double
    var color = "ink"
    var strokeWidth = 3.0
    var style = EaselObjectStyle()
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: point.x * geometry.size.width / width, y: point.y * geometry.size.height / height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }.stroke(EaselColors.object(color), style: style.strokeStyle(strokeWidth))
        }
    }
}

private struct EaselItemEditor: View {
    @State var item: EaselItem
    let save: (EaselItem) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var invalid = false
    @State private var saveFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.kind == .note ? "Write a note" : "Edit item").font(.title2.weight(.semibold))
            if item.kind == .image, let data = item.image {
                EaselCrop(data: data) { item.image = $0 }
            }
            if item.kind == .note {
                TextEditor(text: $item.text).font(.body).frame(height: 220)
                Picker("Color", selection: $item.color) {
                    ForEach(["yellow", "pink", "blue", "green"], id: \.self) { color in Text(color.capitalized).tag(color) }
                }.pickerStyle(.segmented)
            } else {
                TextField("Title", text: $item.text)
                if item.kind == .link || !item.source.isEmpty { TextField("https://…", text: $item.source) }
            }
            if invalid { Text("Enter a valid http or https address.").foregroundStyle(.red).font(.callout) }
            if saveFailed { Text("Your changes could not be saved. They are still here; try again.").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    item.source = item.source.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (item.kind == .link || !item.source.isEmpty) && EaselItem.webURL(item.source) == nil { invalid = true; return }
                    if save(item) { dismiss() } else { saveFailed = true }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 430)
    }
}

/// The Library uses the same repository and window as the File menu.
struct EaselsPane: View {
    @EnvironmentObject private var store: TabStore
    @ObservedObject var repository: EaselStore
    @ObservedObject private var library = Library.shared
    @FocusState private var searchFocused: Bool
    @State private var deleting: EaselBoard?
    @State private var deletionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Look.inkTertiary)
                TextField("Search Easels…", text: $library.query).textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium)).focused($searchFocused)
            }.padding(.horizontal, 14).frame(height: 42)
                .background(Look.controlFill, in: .rect(cornerRadius: 18))
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(repository.boards.filter { Library.matches([$0.title], library.query) }) { board in
                        EaselLibraryCard(board: board, open: { store.openEasel(board.id) },
                                         delete: { deleting = board })
                    }
                }.padding(4)
                if repository.boards.isEmpty || !repository.boards.contains(where: { Library.matches([$0.title], library.query) }) {
                    Text(repository.boards.isEmpty ? "Your Easels will appear here." : "No Easels match your search.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 32)
                }
            }
            HStack {
                Button { store.openEasel(create: true) } label: { Label("New Easel", systemImage: "plus") }
                Spacer()
                Menu {
                    Button("Import Easel…") { importBoard() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More Easel actions")
            }.buttonStyle(.plain).font(.callout).padding(.horizontal, 4).padding(.bottom, 8)
            if let error = repository.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { repository.reload() }
            }
        }.padding(.horizontal, 12).padding(.top, Look.libraryHead).frame(width: Look.easelLibraryList)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { DispatchQueue.main.async { searchFocused = true } }
            .onChange(of: library.focusToken) { searchFocused = true }
            .alert("Delete this Easel?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) {
                    guard let board = deleting else { return }
                    do { try repository.delete(board.id) }
                    catch { deletionError = error.localizedDescription }
                    deleting = nil
                }
            } message: {
                Text("“\(deleting?.title ?? "Untitled Easel")” and all its content will be deleted from this Mac. This cannot be undone.")
            }
            .alert("Easel could not be deleted", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
                Button("OK") { deletionError = nil }
            } message: { Text(deletionError ?? "") }
    }
    private func importBoard() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= EaselStore.fileLimit else {
                throw EaselStore.Failure.tooLarge
            }
            store.openEasel(try repository.importBoard(Data(contentsOf: url)).id)
        } catch { Toasts.show(error.localizedDescription) }
    }
}

private struct EaselLibraryCard: View {
    let board: EaselBoard
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Image(systemName: "scribble.variable").font(.system(size: 22, weight: .bold)).foregroundStyle(.pink)
                Text(board.title.isEmpty ? "Untitled Easel" : board.title)
                    .font(.system(size: 19, weight: .bold)).lineLimit(4)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity).frame(height: 158)
                .background(Look.controlFill, in: .rect(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Look.inkQuiet.opacity(0.18), lineWidth: 1))
                .padding(6).background(hovering ? Look.hovered : Look.controlFill.opacity(0.45), in: .rect(cornerRadius: 21))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Open Easel", action: open)
                    Button("Delete Easel…", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").padding(8) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(8)
                    .accessibilityLabel("Actions for \(board.title)")
            }
            .contextMenu { Button("Delete Easel…", role: .destructive, action: delete) }
            .accessibilityAction(named: "Delete Easel", delete)
    }
}
