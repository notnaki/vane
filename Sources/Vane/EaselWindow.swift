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
        guard ![.drawing, .ellipse, .rectangle, .arrow].contains(item.kind) else { return item }
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
                                    profileID: profileID, liveItems: [], toggleLive: { _ in }, stroke: [], zoom: 1, select: { _ in }, edit: { _ in }, change: { _ in true }, draw: { _, _ in })
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
    @State private var drawing = false
    @State private var drawingKind: EaselItem.Kind = .drawing
    @State private var drawingColor = "cyan"
    @State private var stroke: [EaselPoint] = []
    @State private var editing: EaselItem?
    @State private var title = ""
    @State private var viewport = CGPoint.zero
    @FocusState private var canvasFocused: Bool
    private var board: EaselBoard { repository.board(boardID) ?? EaselBoard() }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ScrollView([.horizontal, .vertical]) {
                EaselCanvas(items: board.items, selected: selected, drawing: drawing,
                            profileID: repository.profileID, liveItems: session.liveItems, toggleLive: session.toggleLive,
                            stroke: stroke, zoom: zoom, drawingKind: drawingKind, drawingColor: drawingColor,
                            select: { selected = $0; canvasFocused = true },
                            edit: { editing = $0 }, change: { changeItem($0) },
                            draw: drawingGesture)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: EaselStore.canvasWidth * zoom, height: EaselStore.canvasHeight * zoom, alignment: .topLeading)
                .focusable().focusEffectDisabled().focused($canvasFocused)
                .onKeyPress(.delete) {
                    guard selected != nil else { return .ignored }; deleteItem(); return .handled
                }
            }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in geometry.contentOffset } action: { _, offset in
                viewport = offset
                session.insertionPoint = CGPoint(x: max(0, offset.x / zoom) + 80, y: max(0, offset.y / zoom) + 140)
            }
            .background(EaselColors.paper)
            toolbar.padding(16)
        }
        .overlay(alignment: .top) {
            TextField("Untitled Easel", text: $title)
                .textFieldStyle(.plain).font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center).frame(maxWidth: 560)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .onChange(of: title) { session.edit { $0.title = String(title.prefix(200)) } }
                .accessibilityLabel("Easel title")
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").help("Saved locally on this Mac")
                Menu("\(Int(zoom * 100))%") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        Button("\(Int(value * 100))%") { zoom = value }
                    }
                }.menuStyle(.borderlessButton).frame(width: 64).accessibilityLabel("Canvas zoom")
            }.font(.caption).padding(12).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(16)
        }
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
        HStack(spacing: 4) {
            tool("Select", "cursorarrow", active: !drawing) { drawing = false }
            tool("Image", "photo") { drawing = false; importImages() }
            tool("Text", "textformat") {
                drawing = false
                let item = EaselItem(kind: .text, color: "ink", fontSize: 28)
                if session.add(item) { selected = item.id }
            }
            tool("Circle", "circle", active: drawing && drawingKind == .ellipse) { chooseDrawing(.ellipse) }
            tool("Rectangle", "square", active: drawing && drawingKind == .rectangle) { chooseDrawing(.rectangle) }
            tool("Arrow", "arrow.up.right", active: drawing && drawingKind == .arrow) { chooseDrawing(.arrow) }
            tool("Pen", "scribble", active: drawing && drawingKind == .drawing) { chooseDrawing(.drawing) }
            Divider().frame(height: 26).padding(.horizontal, 4)
            Menu {
                Button("Add Note") { editing = EaselItem(kind: .note) }
                Button("Add Link") { editing = EaselItem(kind: .link) }
                Button("Paste") { paste() }
                Divider()
                Button("Undo") { session.undo() }.disabled(!repository.canUndo(boardID))
                Button("Redo") { session.redo() }.disabled(!repository.canRedo(boardID))
                Button("Delete Selected Item") { deleteItem() }.disabled(selected == nil)
                Divider()
                Button("Duplicate Easel") {
                    session.perform { openBoard(try repository.importBoard(JSONEncoder().encode(board)).id) }
                }
                Button("Export PNG…") { exportPNG() }
                Button("Export Editable Easel…") { exportBoard() }
                Button("Delete Easel…", role: .destructive) { deleteBoard() }
            } label: { Image(systemName: "plus.square.on.square").frame(width: 38, height: 38) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).help("More Easel actions")
                .accessibilityLabel("More Easel actions")
        }
        .padding(6).background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if drawing {
                EaselPalette(color: drawingColor) { drawingColor = $0 }
                    .padding(10).background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .offset(y: -90)
            }
        }
    }
    private func chooseDrawing(_ kind: EaselItem.Kind) { drawingKind = kind; drawing = true; selected = nil }
    private func tool(_ title: String, _ icon: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 38, height: 38)
                .background(active ? Color.primary.opacity(0.15) : .clear, in: .rect(cornerRadius: 7))
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
        guard stroke.count > 1 else { return }
        let objectPoints = drawingKind == .drawing ? stroke : [stroke[0], stroke[stroke.count - 1]]
        let minX = max(0, (objectPoints.map(\.x).min() ?? 0) - 4)
        let minY = max(0, (objectPoints.map(\.y).min() ?? 0) - 4)
        let maxX = min(EaselStore.canvasWidth, (objectPoints.map(\.x).max() ?? 0) + 4)
        let maxY = min(EaselStore.canvasHeight, (objectPoints.map(\.y).max() ?? 0) + 4)
        let width = min(4096, max(80, maxX - minX)), height = min(4096, max(60, maxY - minY))
        let x = min(minX, EaselStore.canvasWidth - width), y = min(minY, EaselStore.canvasHeight - height)
        let points = objectPoints.map { EaselPoint(x: min(width, max(0, $0.x - x)), y: min(height, max(0, $0.y - y))) }
        let item = EaselItem(kind: drawingKind, points: points, color: drawingColor, x: x, y: y, width: width, height: height)
        if session.add(item) { selected = item.id; drawing = false }
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
    static let paper = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(red: 0.19, green: 0.22, blue: 0.23)
    static let palette = ["ink", "yellow", "orange", "red", "green", "white", "gray", "pink", "cyan", "blue", "purple"]
    static func object(_ color: String) -> Color {
        switch color {
        case "yellow": .yellow
        case "orange": .orange
        case "red": .red
        case "green": .green
        case "white": .white
        case "gray": .gray
        case "pink": .pink
        case "cyan": .cyan
        case "blue": .blue
        case "purple": .purple
        default: Color.primary
        }
    }
    static func card(_ color: String) -> Color {
        switch color {
        case "pink": Color(red: 1, green: 0.84, blue: 0.86)
        case "blue": Color(red: 0.82, green: 0.9, blue: 0.98)
        case "green": Color(red: 0.84, green: 0.92, blue: 0.81)
        default: Color(red: 1, green: 0.93, blue: 0.68)
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
    var drawingKind: EaselItem.Kind = .drawing
    var drawingColor = "ink"
    let select: (UUID?) -> Void
    let edit: (EaselItem) -> Void
    let change: (EaselItem) -> Bool
    let draw: (CGPoint?, Bool) -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            EaselColors.paper.onTapGesture { select(nil) }
            ForEach(items) { item in
                EaselCard(item: item, selected: selected == item.id, profileID: profileID,
                          live: liveItems.contains(item.id), toggleLive: { toggleLive(item.id) }, select: { select(item.id) }, edit: { edit(item) }, change: change)
                    .offset(x: item.x, y: item.y)
                    .allowsHitTesting(!drawing)
            }
            if drawing {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("easel-canvas"))
                        .onChanged { draw($0.location, false) }.onEnded { _ in draw(nil, true) })
                EaselDrawingPreview(points: stroke, kind: drawingKind, color: drawingColor)
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
        .accessibilityLabel("Easel canvas")
    }
}

private struct EaselCard: View {
    let item: EaselItem
    let selected: Bool
    let profileID: UUID
    let live: Bool
    let toggleLive: () -> Void
    let select: () -> Void
    let edit: () -> Void
    let change: (EaselItem) -> Bool
    @State private var textEditing = false
    @State private var textDraft = ""
    @FocusState private var textFocused: Bool
    @GestureState private var movement = CGSize.zero
    @GestureState private var resizing = CGSize.zero
    private var width: Double { min(4096, min(EaselStore.canvasWidth - item.x, max(80, item.width + resizing.width))) }
    private var height: Double { min(4096, min(EaselStore.canvasHeight - item.y, max(60, item.height + resizing.height))) }
    private var arrangedContent: some View {
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .background([.drawing, .text, .ellipse, .rectangle, .arrow].contains(item.kind) ? Color.clear : (item.kind == .note ? EaselColors.card(item.color) : .white),
                        in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.cyan : .black.opacity([.drawing, .text, .ellipse, .rectangle, .arrow].contains(item.kind) ? 0 : 0.1), lineWidth: selected ? 2 : 1))
            .onTapGesture(count: 2) {
                if item.kind == .text { textDraft = item.text; textEditing = true; textFocused = true }
                else { edit() }
            }
            .onTapGesture { if !textEditing { select() } }
            .gesture(DragGesture(coordinateSpace: .named("easel-canvas"))
                .updating($movement) { value, state, _ in state = value.translation }
                .onEnded { value in
                    var updated = item
                    updated.x = min(max(0, item.x + value.translation.width), EaselStore.canvasWidth - item.width)
                    updated.y = min(max(0, item.y + value.translation.height), EaselStore.canvasHeight - item.height)
                    _ = change(updated); select()
                }, including: textEditing ? .none : .all)
    }
    var body: some View {
        arrangedContent
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Circle().fill(EaselColors.paper).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.cyan, lineWidth: 2)).padding(5)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(coordinateSpace: .named("easel-canvas"))
                            .updating($resizing) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                var updated = item
                                updated.width = min(4096, min(EaselStore.canvasWidth - item.x, max(80, item.width + value.translation.width)))
                                updated.height = min(4096, min(EaselStore.canvasHeight - item.y, max(60, item.height + value.translation.height)))
                                updated.points = item.points.map { EaselPoint(x: $0.x * updated.width / item.width, y: $0.y * updated.height / item.height) }
                                _ = change(updated)
                            })
                        .accessibilityLabel("Resize item")
                }
            }
            .overlay(alignment: .topTrailing) { if selected { selectionHandle } }
            .overlay(alignment: .bottomLeading) { if selected { selectionHandle } }
            .overlay(alignment: .topLeading) { if selected { selectionHandle } }
            .onAppear {
                if item.kind == .text && item.text.isEmpty {
                    textDraft = ""; textEditing = true
                    DispatchQueue.main.async { textFocused = true }
                }
            }
            .onChange(of: selected) { if !selected { saveText() } }
            .onDisappear { saveText() }
            .overlay(alignment: .topLeading) {
                if selected && item.kind != .image && item.kind != .link {
                    VStack(spacing: 8) {
                        EaselPalette(color: item.color, choose: { color in
                            var updated = item; updated.color = color; _ = change(updated)
                        }, colors: item.kind == .note ? ["yellow", "pink", "blue", "green"] : EaselColors.palette)
                        if item.kind == .text {
                            HStack {
                                Button { resizeText(-4) } label: { Image(systemName: "minus") }
                                Text("Aa").font(.headline)
                                Button { resizeText(4) } label: { Image(systemName: "plus") }
                            }.buttonStyle(.plain)
                        }
                    }.padding(10).background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .offset(y: item.kind == .text ? -110 : -82)
                }
            }
            .contextMenu {
                Button("Edit…") { edit() }
                if item.kind == .image && !item.source.isEmpty {
                    Button(live ? "Pause Live View" : "View Source Page Live") { toggleLive() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.text.isEmpty ? item.kind.rawValue.capitalized : item.text)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction(named: "Edit") { edit() }
            .accessibilityAction(named: "Move left") { move(dx: -24, dy: 0) }
            .accessibilityAction(named: "Move right") { move(dx: 24, dy: 0) }
            .accessibilityAction(named: "Move up") { move(dx: 0, dy: -24) }
            .accessibilityAction(named: "Move down") { move(dx: 0, dy: 24) }
            .offset(x: movement.width, y: movement.height)
    }
    private var selectionHandle: some View {
        Circle().fill(EaselColors.paper).frame(width: 8, height: 8)
            .overlay(Circle().stroke(.cyan, lineWidth: 2)).allowsHitTesting(false)
    }
    private func resizeText(_ amount: Double) {
        var updated = item; updated.fontSize = min(96, max(12, (item.fontSize ?? 28) + amount)); _ = change(updated)
    }
    private func saveText() {
        guard textEditing else { return }
        var updated = item; updated.text = String(textDraft.prefix(100_000))
        if change(updated) { textEditing = false }
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
                .font(.system(size: 18)).foregroundStyle(EaselColors.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18)
        case .link:
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "link").font(.title2)
                Text(item.text.isEmpty ? item.source : item.text).font(.headline).lineLimit(3)
                Text(item.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
            Group {
                if textEditing {
                    TextField("Start typing to enter text", text: $textDraft, axis: .vertical)
                        .textFieldStyle(.plain).focused($textFocused)
                        .onSubmit { saveText() }
                        .onChange(of: textFocused) { if !textFocused { saveText() } }
                } else {
                    Text(item.text.isEmpty ? "Start typing to enter text" : item.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.font(.system(size: item.fontSize ?? 28, weight: .medium))
                .foregroundStyle(EaselColors.object(item.color)).padding(12)
        case .ellipse, .rectangle, .arrow:
            EaselShape(kind: item.kind, points: item.points, color: item.color, width: item.width, height: item.height)
                .padding(4)
        case .drawing: EaselStroke(points: item.points, width: item.width, height: item.height, color: item.color)
        }
    }
}

struct EaselStroke: View {
    let points: [EaselPoint]
    let width: Double
    let height: Double
    var color = "ink"
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: point.x * geometry.size.width / width, y: point.y * geometry.size.height / height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }.stroke(EaselColors.object(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
