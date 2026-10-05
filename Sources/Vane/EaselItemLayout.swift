import Foundation

/// Object geometry uses screen-space drag deltas, converted once to canvas points.
@MainActor enum EaselItemLayout {
    enum Corner: String, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var leading: Bool { self == .topLeading || self == .bottomLeading }
        var top: Bool { self == .topLeading || self == .topTrailing }
    }
    static func moved(_ item: EaselItem, translation: CGSize, zoom: Double) -> EaselItem {
        var changed = item
        changed.x = min(max(0, item.x + translation.width / zoom), EaselStore.canvasWidth - item.width)
        changed.y = min(max(0, item.y + translation.height / zoom), EaselStore.canvasHeight - item.height)
        return changed
    }
    static func resized(_ item: EaselItem, corner: Corner, translation: CGSize, zoom: Double) -> EaselItem {
        let dx = translation.width / zoom, dy = translation.height / zoom
        var left = item.x, top = item.y, right = item.x + item.width, bottom = item.y + item.height
        if corner.leading { left = min(right - 80, max(0, right - 4096, left + dx)) }
        else { right = max(left + 80, min(EaselStore.canvasWidth, left + 4096, right + dx)) }
        if corner.top { top = min(bottom - 60, max(0, bottom - 4096, top + dy)) }
        else { bottom = max(top + 60, min(EaselStore.canvasHeight, top + 4096, bottom + dy)) }
        var changed = item
        changed.x = left; changed.y = top; changed.width = right - left; changed.height = bottom - top
        changed.points = item.points.map { EaselPoint(x: min(changed.width, max(0, $0.x / item.width * changed.width)), y: min(changed.height, max(0, $0.y / item.height * changed.height))) }
        return changed
    }
    static func created(kind: EaselItem.Kind, color: String, points: [EaselPoint]) -> EaselItem? {
        guard let first = points.first, let last = points.last else { return nil }
        let click = hypot(last.x - first.x, last.y - first.y) < 4
        guard kind == .text || points.count > 1 else { return nil }
        let relevant = kind == .drawing ? points : [first, last]
        let margin = kind == .text ? 0.0 : 4.0
        let minX = max(0, (relevant.map(\.x).min() ?? 0) - margin)
        let minY = max(0, (relevant.map(\.y).min() ?? 0) - margin)
        let maxX = min(EaselStore.canvasWidth, (relevant.map(\.x).max() ?? 0) + margin)
        let maxY = min(EaselStore.canvasHeight, (relevant.map(\.y).max() ?? 0) + margin)
        let width = kind == .text && click ? 280 : min(4096, max(80, maxX - minX))
        let height = kind == .text && click ? 120 : min(4096, max(60, maxY - minY))
        let x = min(minX, EaselStore.canvasWidth - width), y = min(minY, EaselStore.canvasHeight - height)
        let local = relevant.map { EaselPoint(x: min(width, max(0, $0.x - x)), y: min(height, max(0, $0.y - y))) }
        return EaselItem(kind: kind, points: kind == .text ? [] : local, color: color,
                         fontSize: kind == .text ? 20 : nil, x: x, y: y, width: width, height: height)
    }
}
