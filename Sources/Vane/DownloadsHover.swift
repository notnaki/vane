import AppKit
import SwiftUI

@MainActor final class DownloadsHover: ObservableObject {
    enum Region { case button, preview }
    @Published private(set) var isVisible = false
    private var regions: Set<Region> = []
    private var pending: Task<Void, Never>?

    func setHovered(_ hovered: Bool, over region: Region) {
        if hovered { regions.insert(region) } else { regions.remove(region) }
        pending?.cancel()
        let opening = !regions.isEmpty
        guard opening != isVisible else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(opening ? 250 : 180)) }
            catch { return }
            guard let self else { return }
            self.isVisible = opening
            self.pending = nil
        }
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        regions.removeAll()
        isVisible = false
    }
}

enum LibraryHoverCategory: String, CaseIterable, Identifiable {
    case downloads, media, easels, spaces, archived, history, off
    static let key = "libraryHoverCategory"
    var id: String { rawValue }
    var section: LibrarySection? { LibrarySection(rawValue: rawValue) }
    var title: String { section?.title ?? "Off" }
    static func resolve(_ value: String) -> Self { Self(rawValue: value) ?? .downloads }
    func available(isPrivate: Bool) -> Bool {
        !isPrivate || self == .downloads || self == .media || self == .archived || self == .off
    }
}

@MainActor enum LibraryHoverItem: @MainActor Identifiable {
    case download(Downloads.Item), easel(EaselBoard), space(Space), archived(Archive.Entry), history(Visit)
    var id: String {
        switch self {
        case .download(let item): "download-\(item.id)"
        case .easel(let board): "easel-\(board.id)"
        case .space(let space): "space-\(space.id)"
        case .archived(let entry): "archive-\(entry.id)"
        case .history(let visit): "history-\(visit.id)"
        }
    }

    static func recent(_ category: LibraryHoverCategory, downloads: [Downloads.Item] = [],
                       boards: [EaselBoard] = [], spaces: [Space] = [],
                       archived: [Archive.Entry] = [], history: [Visit] = [],
                       isPrivate: Bool = false) -> [Self] {
        guard category.available(isPrivate: isPrivate) else { return [] }
        let rows: [Self]
        switch category {
        case .downloads: rows = downloads.prefix(4).map(Self.download)
        case .media:
            rows = downloads.filter { $0.status == .done && Library.isImage(name: $0.name) }
                .prefix(4).map(Self.download)
        case .easels:
            rows = boards.sorted { $0.modified > $1.modified }.prefix(4).map(Self.easel)
        // Spaces are kept in sidebar order, with newly created Spaces appended.
        case .spaces: return spaces.suffix(4).map(Self.space)
        case .archived:
            rows = archived.sorted { $0.at > $1.at }.prefix(4).map(Self.archived)
        case .history:
            rows = history.sorted { $0.at > $1.at }.prefix(4).map(Self.history)
        case .off: return []
        }
        return rows.reversed()
    }
}

/// Four items from the selected Library section, newest nearest the bucket.
struct RecentLibraryPreview: View {
    let items: [LibraryHoverItem]
    let category: LibraryHoverCategory
    @ObservedObject var downloads: DownloadLibrary
    @ObservedObject var store: TabStore
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    switch item {
                    case .download(let download):
                        if let owner = downloads.owner(of: download) {
                            RecentDownloadRow(item: download, downloads: owner, close: close)
                        }
                    default:
                        RecentLibraryRow(item: item) {
                            close()
                            switch item {
                            case .easel(let board): _ = store.openEasel(board.id)
                            case .space(let space): store.switchTo(space: space)
                            case .archived(let entry): store.restore(entry)
                            case .history(let visit):
                                if let url = URL(string: visit.url) { store.newTab(url) }
                            case .download: break
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .padding(.horizontal, Look.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent \(category.title)")
    }
}

private struct RecentLibraryRow: View {
    let item: LibraryHoverItem
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    private var title: String {
        switch item {
        case .easel(let board): board.title
        case .space(let space): space.name
        case .archived(let entry): entry.title
        case .history(let visit): visit.display
        case .download(let item): item.name
        }
    }
    private var date: Date? {
        switch item {
        case .easel(let board): board.modified
        case .archived(let entry): entry.at
        case .history(let visit): visit.at
        default: nil
        }
    }
    private var symbol: String {
        switch item {
        case .easel: "scribble.variable"
        case .space(let space): space.icon ?? "square.on.square"
        case .archived: "tray.full"
        case .history: "clock"
        case .download: "arrow.down.circle"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22))
                    .frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Look.inkPrimary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(date?.formatted(.relative(presentation: .numeric)) ?? spaceSubtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Look.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 48).contentShape(.rect)
            .background(hovered ? Look.selected : Look.pillFill,
                        in: .rect(cornerRadius: Look.pillRadius))
        }
        .buttonStyle(TactileButtonStyle())
        .foregroundStyle(Look.inkSecondary)
        .onHover { hovered = $0 }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: hovered)
    }

    private var spaceSubtitle: String {
        guard case .space(let space) = item else { return "" }
        let count = space.tabURLs.count + (space.pinnedTabURLs?.count ?? 0) + space.pinnedURLs.count
        return "\(count) tab\(count == 1 ? "" : "s")"
    }
}

private struct RecentDownloadRow: View {
    @ObservedObject var item: Downloads.Item
    let downloads: Downloads
    let close: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        Button {
            if item.status == .done { close(); downloads.open(item) }
        } label: {
            HStack(spacing: 12) {
                DownloadIcon(item: item, size: 40).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Look.inkPrimary).lineLimit(1)
                        .truncationMode(.tail)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(item.status == .done
                            ? item.completed?.formatted(.relative(presentation: .numeric)) ?? item.subtitle
                            : item.subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Look.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 48)
            .contentShape(.rect)
            .background(hovered ? Look.selected : Look.pillFill,
                        in: .rect(cornerRadius: Look.pillRadius))
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: hovered)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.spoken)
        .accessibilityHint(item.status == .done ? "Opens this download." : "")
        .contextMenu {
            if item.status == .done {
                Button("Open") { close(); downloads.open(item) }
                Button("Show in Finder") { close(); downloads.reveal(item) }
            }
        }
    }
}

/// The open bucket stays recognizable as its contents lift toward the pointer.
/// An empty bucket lifts its lid; a full one lifts its contents and glows on hover.
struct LibraryBucket: View {
    let filled: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BucketShape().fill(style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 0.75)
                .frame(width: 14, height: 1.5).offset(y: hovered ? -3.5 : -0.5)
                .opacity(filled ? 0 : 1)
            if filled {
                ZStack {
                    BucketConfetti(points: 5)
                        .frame(width: 10, height: 9)
                        .rotationEffect(.degrees(-14))
                        .offset(x: -2, y: hovered ? -2.5 : 0.5)
                    BucketConfetti(points: 3)
                        .frame(width: 3.5, height: 3.5)
                        .rotationEffect(.degrees(18))
                        .offset(x: hovered ? 6.5 : 4.5, y: hovered ? -2 : 0)
                    Circle().frame(width: 2, height: 2)
                        .offset(x: hovered ? 3 : 2, y: hovered ? -6.5 : -4.5)
                }
                .frame(width: 24, height: 24)
                // Contents sit behind the opening, then lift out at their original size.
                .mask(alignment: .top) { Rectangle().frame(height: 13) }
                .foregroundStyle(hovered ? Look.inkPrimary : Look.inkSecondary)
                .shadow(color: .white.opacity(hovered ? 0.7 : 0), radius: hovered ? 5 : 0)
            }
        }
        .frame(width: 24, height: 24)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.25), value: hovered)
        .animation(reduceMotion ? nil : Look.quick, value: filled)
        .accessibilityHidden(true)
    }
}

private struct BucketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 3,
                                            bottomTrailingRadius: 3, topTrailingRadius: 1)
            .path(in: CGRect(x: 6, y: 14, width: 12, height: 9)))
        path.addRoundedRect(in: CGRect(x: 10, y: 15, width: 4, height: 2),
                            cornerSize: CGSize(width: 1, height: 1))
        return path
    }
}

private struct BucketConfetti: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let count = points == 5 ? 10 : 3
        let vertices = (0..<count).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
            let radius = points == 5 && index % 2 == 1 ? 0.48 : 1.0
            return CGPoint(x: rect.midX + cos(angle) * radius * rect.width / 2,
                           y: rect.midY + sin(angle) * radius * rect.height / 2)
        }
        func toward(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * 0.22, y: a.y + (b.y - a.y) * 0.22)
        }
        var path = Path()
        path.move(to: toward(vertices[0], vertices[count - 1]))
        for index in vertices.indices {
            let vertex = vertices[index]
            path.addLine(to: toward(vertex, vertices[(index + count - 1) % count]))
            path.addQuadCurve(to: toward(vertex, vertices[(index + 1) % count]), control: vertex)
        }
        path.closeSubpath()
        return path
    }
}
