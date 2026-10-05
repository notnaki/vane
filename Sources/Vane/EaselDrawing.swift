import SwiftUI

struct EaselPalette: View {
    let color: String
    let choose: (String) -> Void
    var colors = EaselColors.palette
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 7), count: 6), spacing: 7) {
            ForEach(colors, id: \.self) { value in
                Button { choose(value) } label: {
                    Circle().fill(EaselColors.object(value))
                        .overlay(Circle().stroke(.primary.opacity(0.2), lineWidth: 1))
                        .overlay {
                            if value == color {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(value == "ink" ? EaselColors.paper : (value == "blue" || value == "purple" ? .white : .black))
                            }
                        }.frame(width: 22, height: 22)
                }.buttonStyle(.plain).help(value.capitalized)
                    .accessibilityLabel(value.capitalized)
                    .accessibilityAddTraits(value == color ? [.isSelected] : [])
            }
        }.frame(width: 167)
    }
}

struct EaselShape: View {
    let kind: EaselItem.Kind
    let points: [EaselPoint]
    let color: String
    let width: Double
    let height: Double
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                switch kind {
                case .ellipse: path.addEllipse(in: bounds)
                case .rectangle: path.addRect(bounds)
                case .arrow:
                    guard let first = points.first, let last = points.last else { return }
                    let start = CGPoint(x: first.x / width * bounds.width, y: first.y / height * bounds.height)
                    let end = CGPoint(x: last.x / width * bounds.width, y: last.y / height * bounds.height)
                    path.move(to: start); path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head = min(24.0, hypot(end.x - start.x, end.y - start.y) * 0.3)
                    for turn in [-0.6, 0.6] {
                        path.move(to: CGPoint(x: end.x - head * cos(angle + turn), y: end.y - head * sin(angle + turn)))
                        path.addLine(to: end)
                    }
                default: break
                }
            }.stroke(EaselColors.object(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

struct EaselDrawingPreview: View {
    let points: [EaselPoint]
    let kind: EaselItem.Kind
    let color: String
    var body: some View {
        if kind == .drawing {
            EaselStroke(points: points, width: EaselStore.canvasWidth, height: EaselStore.canvasHeight, color: color)
        } else if let first = points.first, let last = points.last {
            let x = min(first.x, last.x), y = min(first.y, last.y)
            let width = max(1, abs(last.x - first.x)), height = max(1, abs(last.y - first.y))
            EaselShape(kind: kind, points: [EaselPoint(x: first.x - x, y: first.y - y), EaselPoint(x: last.x - x, y: last.y - y)],
                       color: color, width: width, height: height)
                .frame(width: width, height: height).offset(x: x, y: y)
        }
    }
}
