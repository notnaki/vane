import SwiftUI

struct EaselPalette: View {
    let color: String
    let choose: (String) -> Void
    var colors = ["ink", "red", "green", "blue", "orange"]
    var fill = false
    var allowsTransparent = true
    @State private var expanded = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(colors, id: \.self) { value in swatch(value, size: 22, selectable: true) }
            Divider().frame(height: 20).padding(.horizontal, 3)
            Button { expanded.toggle() } label: { swatch(color, size: 26, selectable: false) }
                .buttonStyle(.plain).help(fill ? "Show background color picker" : "Show stroke color picker")
                .accessibilityLabel(fill ? "Show background color picker" : "Show stroke color picker")
                .popover(isPresented: $expanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 6), spacing: 6) {
                            ForEach((fill && allowsTransparent ? ["none"] : []) + EaselColors.palette, id: \.self) { value in swatch(value, size: 26, selectable: true) }
                        }
                        ColorPicker("Custom color", selection: Binding(get: { EaselColors.object(color) }, set: { choose(EaselColors.hex($0)) }), supportsOpacity: false)
                    }.padding(14)
                }
        }
    }
    private func swatch(_ value: String, size: Double, selectable: Bool) -> some View {
        let face = RoundedRectangle(cornerRadius: 4).fill(value == "none" ? .clear : fill ? EaselColors.fill(value) : EaselColors.object(value))
            .overlay { if value == "none" { Image(systemName: "square.dashed").font(.system(size: 16)).foregroundStyle(.secondary) } }
            .frame(width: size, height: size)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(value == color && selectable ? EaselColors.selection : .clear, lineWidth: 1))
        return Group {
            if selectable {
                Button { choose(value) } label: { face }.buttonStyle(.plain).help(value == "none" ? "Transparent" : value.capitalized)
                    .accessibilityLabel(value == "none" ? "Transparent" : value.capitalized)
                    .accessibilityAddTraits(value == color ? [.isSelected] : [])
            } else { face }
        }
    }
}

struct EaselShape: View {
    let kind: EaselItem.Kind
    let points: [EaselPoint]
    let color: String
    let width: Double
    let height: Double
    var strokeWidth = 3.0
    var fillColor: String?
    var style = EaselObjectStyle()
    static func diamondPath(in bounds: CGRect, edges: EaselObjectStyle.Edges) -> Path {
        let corners = [CGPoint(x: bounds.midX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.midY),
                       CGPoint(x: bounds.midX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.midY)]
        func inset(_ corner: CGPoint, toward next: CGPoint) -> CGPoint {
            let distance = hypot(next.x - corner.x, next.y - corner.y)
            let amount = min(20, distance / 4) / max(1, distance)
            return CGPoint(x: corner.x + (next.x - corner.x) * amount, y: corner.y + (next.y - corner.y) * amount)
        }
        return Path { path in
            if edges == .round {
                path.move(to: inset(corners[0], toward: corners[3]))
                for index in corners.indices {
                    let corner = corners[index]
                    path.addQuadCurve(to: inset(corner, toward: corners[(index + 1) % 4]), control: corner)
                    path.addLine(to: inset(corners[(index + 1) % 4], toward: corner))
                }
            } else {
                path.move(to: corners[0])
                for corner in corners.dropFirst() { path.addLine(to: corner) }
            }
            path.closeSubpath()
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let shape = Path { path in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                switch kind {
                case .ellipse: path.addEllipse(in: bounds)
                case .rectangle:
                    if style.edges == .round { path.addRoundedRect(in: bounds, cornerSize: CGSize(width: min(20, bounds.width / 4), height: min(20, bounds.height / 4))) }
                    else { path.addRect(bounds) }
                case .diamond:
                    path.addPath(Self.diamondPath(in: bounds, edges: style.edges))
                case .arrow, .line:
                    guard let first = points.first, let last = points.last else { return }
                    let start = CGPoint(x: first.x / width * bounds.width, y: first.y / height * bounds.height)
                    let end = CGPoint(x: last.x / width * bounds.width, y: last.y / height * bounds.height)
                    path.move(to: start); path.addLine(to: end)
                    guard kind == .arrow else { return }
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head = min(24.0, hypot(end.x - start.x, end.y - start.y) * 0.3)
                    for turn in [-0.6, 0.6] {
                        path.move(to: CGPoint(x: end.x - head * cos(angle + turn), y: end.y - head * sin(angle + turn)))
                        path.addLine(to: end)
                    }
                default: break
                }
            }
            if let fillColor, [.rectangle, .diamond, .ellipse].contains(kind) {
                if style.fill == .solid { shape.fill(EaselColors.fill(fillColor).opacity(0.75)) }
                else {
                    Path { hatch in
                        let w = geometry.size.width, h = geometry.size.height
                        for x in stride(from: -h, through: w + h, by: 9) {
                            hatch.move(to: CGPoint(x: x, y: 0)); hatch.addLine(to: CGPoint(x: x + h, y: h))
                            if style.fill == .crosshatch {
                                hatch.move(to: CGPoint(x: x, y: 0)); hatch.addLine(to: CGPoint(x: x - h, y: h))
                            }
                        }
                    }.stroke(EaselColors.fill(fillColor).opacity(0.9), lineWidth: 1).clipShape(shape)
                }
            }
            EaselSketch.path(shape, roughness: style.roughness).stroke(EaselColors.object(color), style: style.strokeStyle(strokeWidth))
            if style.roughness > 0 {
                EaselSketch.path(shape, roughness: style.roughness, pass: 1)
                    .stroke(EaselColors.object(color).opacity(0.55), style: style.strokeStyle(strokeWidth * 0.7))
            }
        }
    }
}

struct EaselDrawingPreview: View {
    let points: [EaselPoint]
    let kind: EaselItem.Kind
    let color: String
    var strokeWidth = 3.0
    var fillColor: String?
    var style = EaselObjectStyle()
    var body: some View {
        if kind == .drawing {
            EaselStroke(points: points, width: EaselStore.canvasWidth, height: EaselStore.canvasHeight, color: color, strokeWidth: strokeWidth, style: style)
        } else if let first = points.first, let last = points.last {
            let x = min(first.x, last.x), y = min(first.y, last.y)
            let width = max(1, abs(last.x - first.x)), height = max(1, abs(last.y - first.y))
            EaselShape(kind: kind == .text ? .rectangle : kind, points: [EaselPoint(x: first.x - x, y: first.y - y), EaselPoint(x: last.x - x, y: last.y - y)],
                       color: color, width: width, height: height, strokeWidth: strokeWidth, fillColor: kind == .text ? nil : fillColor, style: style)
                .frame(width: width, height: height).offset(x: x, y: y)
        }
    }
}
