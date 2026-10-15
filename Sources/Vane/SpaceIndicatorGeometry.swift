import AppKit
import SwiftUI

/// Cached symbol geometry, independent of progress. A small distance grid allows any SF
/// glyph (including holes) to grow out of the dot without a replacement-effect balloon.
struct SpaceIndicatorGeometry: Sendable {
    static let cells = 40
    let extent: CGFloat
    let dotSize: CGFloat
    let dot: [Double]
    let symbol: [Double]
    let dotArea: Double
    let symbolArea: Double
    private struct Band: Sendable { let lower: Double; let upper: Double; let cells: [Int] }
    private let bands: [Band]
    private var endpoint: Path?

    @MainActor init(image: NSImage, dotSize: CGFloat) {
        self.dotSize = dotSize
        let extent = max(image.size.width, image.size.height, dotSize) + 2
        self.extent = extent
        let n = Self.cells + 1
        let scale = CGFloat(Self.cells) / extent
        let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: (extent - image.size.width) / 2,
                              y: (extent - image.size.height) / 2,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // NSImage draws its symbol into this AppKit context in the orientation used by
        // the SwiftUI shape. A second row inversion flips the live footer upside down.
        let mask = (0..<n*n).map { k in bytes[k * 4 + 3] >= 128 }
        let boundary = (0..<n*n).filter { k in
            let x = k % n, y = k / n
            return (x > 0 && mask[k] != mask[k - 1]) || (x + 1 < n && mask[k] != mask[k + 1])
                || (y > 0 && mask[k] != mask[k - n]) || (y + 1 < n && mask[k] != mask[k + n])
        }
        let dot = (0..<n*n).map { k in
            hypot(Double(k % n) / Double(scale) - Double(extent / 2),
                  Double(k / n) / Double(scale) - Double(extent / 2)) - Double(dotSize / 2)
        }
        let symbol = (0..<n*n).map { k in
            let x = k % n, y = k / n
            let squared = boundary.reduce(Double.infinity) { best, b in
                let dx = x - b % n, dy = y - b / n
                return min(best, Double(dx * dx + dy * dy))
            }
            return (sqrt(squared) + 0.5) / Double(scale) * (mask[k] ? -1 : 1)
        }
        self.dot = dot
        self.symbol = symbol
        let dotArea = Double(dot.filter { $0 < 0 }.count)
        let symbolArea = Double(mask.filter { $0 }.count)
        self.dotArea = dotArea
        self.symbolArea = symbolArea
        func value(_ k: Int, _ f: Double) -> Double {
            dot[k] >= 0 && symbol[k] >= 0 ? 1000 : dot[k] + (symbol[k] - dot[k]) * f
        }
        // Solve area-preserving levels and potentially crossed cells once. Per-frame
        // geometry interpolates continuously inside these bands without sorting a grid.
        let steps = 32
        let levels = (0...steps).map { step -> Double in
            if step == 0 || step == steps { return 0 }
            let f = Double(step) / Double(steps)
            let ordered = dot.indices.map { value($0, f) }.sorted()
            let rank = min(Double(ordered.count - 2), max(0, dotArea + (symbolArea - dotArea)*f - 0.5))
            let index = Int(rank)
            return ordered[index] + (ordered[index+1] - ordered[index]) * (rank - Double(index))
        }
        bands = (0..<steps).map { step in
            let lowerF = Double(step) / Double(steps), upperF = Double(step+1) / Double(steps)
            var cells: [Int] = []
            for y in 0..<Self.cells {
                for x in 0..<Self.cells {
                    let k = y*n+x
                    let ids = [k, k+1, k+n, k+n+1]
                    let lower = ids.map { value($0, lowerF) < levels[step] }
                    let upper = ids.map { value($0, upperF) < levels[step+1] }
                    if lower != upper || lower.contains(true) && lower.contains(false)
                        || upper.contains(true) && upper.contains(false) { cells.append(k) }
                }
            }
            return Band(lower: levels[step], upper: levels[step+1], cells: cells)
        }
        endpoint = nil
        endpoint = path(progress: 1, in: CGRect(x: 0, y: 0, width: extent, height: extent))
    }

    func path(progress: Double, in rect: CGRect) -> Path {
        let f = min(1, max(0, progress))
        if f == 0 {
            return Path(ellipseIn: CGRect(x: rect.midX - dotSize / 2, y: rect.midY - dotSize / 2,
                                          width: dotSize, height: dotSize))
        }
        if f == 1, let endpoint {
            return endpoint.offsetBy(dx: rect.midX - extent / 2, dy: rect.midY - extent / 2)
        }
        let n = Self.cells + 1
        let position = f * Double(bands.count)
        let index = min(bands.count - 1, Int(position))
        let band = bands[index]
        let blend = position - Double(index)
        let level = band.lower + (band.upper - band.lower) * blend
        func value(_ k: Int) -> Double {
            let distance = dot[k] + (symbol[k] - dot[k])*f
            // Outside the endpoint union stays outside, but retain its real distance
            // for subpixel interpolation rather than pinning the contour to grid nodes.
            return dot[k] >= 0 && symbol[k] >= 0 ? distance : distance - level
        }
        var points: [Int: CGPoint] = [:]
        var neighbours: [Int: [Int]] = [:]
        let verticalBase = n * Self.cells
        let unit = extent / CGFloat(Self.cells)
        let origin = CGPoint(x: rect.midX - extent / 2, y: rect.midY - extent / 2)
        func connect(_ a: Int, _ b: Int) {
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }
        for start in band.cells {
            let x = start % n, y = start / n
            let ids = [start, start+1, start+n+1, start+n]
            let edges = [y*Self.cells+x, verticalBase+y*n+x+1,
                         (y+1)*Self.cells+x, verticalBase+y*n+x]
            let values = ids.map { value($0) }
            var crossed: [Int] = []
            for e in 0..<4 {
                let a = ids[e], b = ids[(e + 1) % 4]
                let va = values[e], vb = values[(e+1) % 4]
                guard (va < 0) != (vb < 0) else { continue }
                let t = va / (va - vb)
                let px = Double(a % n) + Double(b % n - a % n) * t
                let py = Double(a / n) + Double(b / n - a / n) * t
                points[edges[e]] = CGPoint(x: origin.x + CGFloat(px)*unit, y: origin.y + CGFloat(py)*unit)
                crossed.append(e)
            }
            if crossed.count == 2 { connect(edges[crossed[0]], edges[crossed[1]]) }
            else if crossed.count == 4 {
                let centerInside = values.reduce(0, +) < 0
                if (values[0] < 0) == centerInside {
                    connect(edges[0], edges[1]); connect(edges[2], edges[3])
                } else {
                    connect(edges[0], edges[3]); connect(edges[1], edges[2])
                }
            }
        }
        var path = Path(), visited = Set<Int>()
        for first in neighbours.keys where !visited.contains(first) {
            guard let point = points[first] else { continue }
            path.move(to: point)
            var previous = -1, current = first
            repeat {
                visited.insert(current)
                guard let next = neighbours[current]?.first(where: { $0 != previous }),
                      let point = points[next] else { break }
                path.addLine(to: point)
                previous = current
                current = next
            } while current != first && !visited.contains(current)
            path.closeSubpath()
        }
        return path
    }
}

@MainActor enum SpaceIndicatorGeometryCache {
    struct Entry { let image: NSImage; let geometry: SpaceIndicatorGeometry }
    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []
    static func entry(icon: String, iconSize: CGFloat, dotSize: CGFloat) -> Entry {
        let key = "\(icon):\(iconSize):\(dotSize)"
        if let entry = entries[key] { return entry }
        let image = (NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)!)
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))!
        let entry = Entry(image: image, geometry: SpaceIndicatorGeometry(image: image, dotSize: dotSize))
        if order.count == 32 { entries.removeValue(forKey: order.removeFirst()) }
        entries[key] = entry
        order.append(key)
        return entry
    }
}

struct SpaceIndicatorMorph: Shape {
    let geometry: SpaceIndicatorGeometry
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path { geometry.path(progress: progress, in: rect) }
}
