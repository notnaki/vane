import AppKit
import SwiftUI

@MainActor final class CaptureResultState: ObservableObject {
    @Published var busy = false
    @Published var saved = false
    @Published var error: String?
    @Published var query = ""
    @Published var menuWidth: CGFloat = 248
    @Published var availableHeight: CGFloat = 460
}

enum CaptureOutputAction {
    case copy, save, share, library, edit, retake, easel(UUID?)
}

struct CaptureActionMenu: View {
    @ObservedObject var state: CaptureResultState
    let canRetake: Bool
    let canSaveToLibrary: Bool
    let canAddToEasel: Bool
    let boards: [EaselBoard]
    let theme: SpaceChromeTheme
    let perform: (CaptureOutputAction) -> Void
    let close: () -> Void
    @State private var hovered: String?

    private struct Item: Identifiable {
        let id: String
        let title: String
        let icon: String
        let group: Int
        let action: CaptureOutputAction
    }
    private var items: [Item] {
        var rows: [Item] = [
            Item(id: "copy", title: "Copy", icon: "doc.on.clipboard", group: 0, action: .copy),
            Item(id: "save", title: "Save…", icon: "square.and.arrow.down", group: 0, action: .save),
            Item(id: "share", title: "Share…", icon: "square.and.arrow.up", group: 0, action: .share),
        ]
        if canSaveToLibrary {
            rows.insert(Item(id: "library", title: state.saved ? "Saved to Library" : "Save to Library", icon: "photo.on.rectangle", group: 0, action: .library), at: 0)
        }
        rows.append(Item(id: "edit", title: "Edit…", icon: "pencil.tip.crop.circle", group: 1, action: .edit))
        if canRetake { rows.append(Item(id: "retake", title: "Retake", icon: "arrow.counterclockwise", group: 1, action: .retake)) }
        if canAddToEasel {
            rows.append(Item(id: "new", title: "New Easel", icon: "plus", group: 2, action: .easel(nil)))
            rows += boards.map { Item(id: $0.id.uuidString, title: $0.title.isEmpty ? "Untitled Easel" : $0.title,
                icon: "scribble.variable", group: 2, action: .easel($0.id)) }
        }
        return rows.filter { state.query.isEmpty || $0.title.localizedStandardContains(state.query) }
    }
    private var listHeight: CGFloat {
        let separators = max(0, Set(items.map(\.group)).count - 1)
        let content = max(34, CGFloat(items.count) * 36 - 2 + CGFloat(separators) * 13)
        let footer: CGFloat = state.error == nil ? 0 : 54
        return min(content, max(34, state.availableHeight - 66 - footer))
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Send To…", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .accessibilityLabel("Filter capture actions")
                    .onSubmit { if !state.busy, let item = items.first { perform(item.action) } }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6)).frame(width: 20, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Close capture").keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 6))
            ScrollView {
                VStack(spacing: 2) {
                    if items.isEmpty {
                        Text("No matching actions").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 && items[index - 1].group != item.group {
                            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 5)
                        }
                        row(item)
                    }
                }
            }.frame(height: listHeight)
            if state.busy { ProgressView().controlSize(.small).tint(.white).accessibilityLabel("Saving capture") }
            if let error = state.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    .accessibilityLabel("Capture error: \(error)")
            }
        }
        .padding(8).frame(width: max(0, state.menuWidth))
        .foregroundStyle(.white.opacity(0.92))
        .background(theme.bubble, in: .rect(cornerRadius: 10))
        .environment(\.colorScheme, .dark).tint(theme.accent)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.reduced ? nil : Look.quick, value: state.busy)
    }
    private func row(_ item: Item) -> some View {
        Button { perform(item.action) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon).font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6)).frame(width: 20)
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 34)
            .contentShape(Rectangle())
            .background(hovered == item.id ? theme.bubbleHover : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain).disabled(state.busy || (item.id == "library" && state.saved))
        .onHover { hovered = $0 ? item.id : nil }
        .animation(Motion.reduced ? nil : Look.quick, value: hovered == item.id)
        .help(item.title)
    }
}

@MainActor final class CaptureMenuHostingView: NSHostingView<CaptureActionMenu> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

struct CaptureInstructions: View {
    let fullPage: () -> Void
    let cancel: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text("Click an element or drag to capture").font(.system(size: 13, weight: .medium))
                controls
            }
            VStack(spacing: 8) {
                Text("Click or drag to capture").font(.system(size: 13, weight: .medium))
                controls
            }
        }
        .padding(12).foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Look.pillRadius))
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Button("Full Page", systemImage: "rectangle.expand.vertical", action: fullPage).buttonStyle(.borderedProminent)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }.controlSize(.small)
    }
}
