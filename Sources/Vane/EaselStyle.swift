import AppKit
import CoreText
import SwiftUI

struct EaselObjectStyle: Codable, Equatable {
    enum FontFamily: String, Codable, CaseIterable { case handwritten, normal, code }
    enum TextAlignment: String, Codable, CaseIterable { case left, center, right }
    enum Stroke: String, Codable, CaseIterable { case solid, dashed, dotted }
    enum Fill: String, Codable, CaseIterable { case solid, hachure, crosshatch }
    enum Edges: String, Codable, CaseIterable { case sharp, round }
    var fontFamily = FontFamily.normal
    var textAlignment = TextAlignment.left
    var stroke = Stroke.solid
    var fill = Fill.solid
    var edges = Edges.sharp
    var roughness = 0.0
    var opacity = 1.0
    func validate() throws {
        guard roughness.isFinite, (0...2).contains(roughness), opacity.isFinite, (0...1).contains(opacity)
        else { throw EaselStore.Failure.invalid }
    }
    func strokeStyle(_ width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                    dash: stroke == .dashed ? [width * 4, width * 3] : stroke == .dotted ? [0.1, width * 3] : [])
    }
    var alignment: SwiftUI.TextAlignment {
        switch textAlignment { case .left: .leading; case .center: .center; case .right: .trailing }
    }
}

@MainActor enum EaselTypography {
    static let fontURL = Bundle.module.url(forResource: "Excalifont-Regular", withExtension: "ttf", subdirectory: "EaselFonts")
    private static let loaded: Void = {
        for name in ["Excalifont-Regular", "Nunito-Regular", "ComicShanns-Regular"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "EaselFonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func font(_ family: EaselObjectStyle.FontFamily, size: Double) -> Font {
        _ = loaded
        switch family {
        case .handwritten:
            return .custom("Excalifont-Regular", size: size)
        case .normal: return .custom("NunitoExtraLight-Medium", size: size)
        case .code: return .custom("ComicShanns-Regular", size: size)
        }
    }
}

struct EaselStylePanel: View {
    let style: EaselObjectStyle
    let shape: Bool
    let text: Bool
    var closedShape = true
    var filled = false
    var fontSize = 20.0
    var strokeWidth = 2.0
    let change: (EaselObjectStyle) -> Void
    var changeFont: (Double) -> Void = { _ in }
    var changeStroke: (Double) -> Void = { _ in }
    var layer: ((Int) -> Void)?
    @State private var opacity = 1.0
    @State private var adjustingOpacity = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if shape {
                if filled && closedShape {
                    choices("Fill", values: [.hachure, .crosshatch, .solid] as [EaselObjectStyle.Fill], selected: style.fill) { $0.fill = $1 }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Stroke width").font(.caption)
                    HStack(spacing: 8) {
                        ForEach([1.0, 2, 4], id: \.self) { width in
                            option("Stroke width: \(width == 1 ? "Thin" : width == 2 ? "Medium" : "Bold")", selected: strokeWidth == width) {
                                changeStroke(width)
                            } content: { Capsule().frame(width: 12, height: width) }
                        }
                    }
                }
                choices("Stroke style", values: EaselObjectStyle.Stroke.allCases, selected: style.stroke) { $0.stroke = $1 }
                choices("Sloppiness", values: [0.0, 1, 2], selected: style.roughness,
                        names: ["Architect", "Artist", "Cartoonist"]) { $0.roughness = $1 }
                if closedShape { choices("Edges", values: EaselObjectStyle.Edges.allCases, selected: style.edges) { $0.edges = $1 } }
            }
            if text {
                choices("Font family", values: EaselObjectStyle.FontFamily.allCases, selected: style.fontFamily) { $0.fontFamily = $1 }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Font size").font(.caption)
                    HStack(spacing: 8) {
                        ForEach(Array([16.0, 20, 28, 36].enumerated()), id: \.offset) { index, size in
                            let name = ["S", "M", "L", "XL"][index]
                            option("Font size: \(name)", selected: fontSize == size) { changeFont(size) }
                                content: { Text(name).font(.system(size: 12)) }
                        }
                    }
                }
                choices("Text align", values: EaselObjectStyle.TextAlignment.allCases, selected: style.textAlignment) { $0.textAlignment = $1 }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Opacity").font(.caption)
                Slider(value: $opacity, in: 0...1) { active in
                    adjustingOpacity = active
                    if !active { var updated = style; updated.opacity = opacity; change(updated) }
                }.tint(EaselColors.selection).accessibilityLabel("Object opacity")
                HStack { Text("0"); Spacer(); Text("\(Int(opacity * 100))") }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Layers").font(.caption)
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        option(["Send to back", "Send backward", "Bring forward", "Bring to front"][index], selected: false) { layer?(index) }
                            content: { Image(systemName: ["arrow.down.to.line", "arrow.down", "arrow.up", "arrow.up.to.line"][index]) }
                    }
                }.disabled(layer == nil)
            }
        }.onAppear { opacity = style.opacity }
            .onChange(of: style.opacity) { if !adjustingOpacity { opacity = style.opacity } }
            .onChange(of: opacity) {
                if !adjustingOpacity && opacity != style.opacity { var updated = style; updated.opacity = opacity; change(updated) }
            }
    }
    private func choices<T: Hashable>(_ title: String, values: [T], selected: T, names: [String]? = nil,
                                      update: @escaping (inout EaselObjectStyle, T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption)
            HStack(spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    let label = names?[index] ?? String(describing: value).capitalized
                    option("\(title): \(label)", selected: selected == value) {
                        var updated = style; update(&updated, value); change(updated)
                    } content: { EaselOptionGlyph(section: title, value: String(describing: value)) }
                }
            }
        }
    }
    private func option<Content: View>(_ label: String, selected: Bool, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content().font(.system(size: 12)).frame(width: 32, height: 32)
                .background(selected ? EaselColors.selection.opacity(0.2) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 7))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct EaselOptionGlyph: View {
    let section: String
    let value: String
    var body: some View {
        switch section {
        case "Stroke style":
            Path { path in path.move(to: CGPoint(x: 0, y: 8)); path.addLine(to: CGPoint(x: 14, y: 8)) }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: value == "dashed" ? [2, 2] : value == "dotted" ? [0.1, 2] : []))
                .frame(width: 14, height: 16)
        case "Sloppiness":
            Path { path in
                path.move(to: CGPoint(x: 0, y: 10))
                path.addCurve(to: CGPoint(x: 14, y: 7), control1: CGPoint(x: 8, y: value == "0.0" ? 8 : 1), control2: CGPoint(x: 5, y: value == "2.0" ? 16 : 12))
            }.stroke(style: StrokeStyle(lineWidth: value == "2.0" ? 1.8 : 1.3, lineCap: .round)).frame(width: 14, height: 16)
        case "Edges":
            RoundedRectangle(cornerRadius: value == "round" ? 5 : 0)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5])).frame(width: 14, height: 14)
        case "Fill":
            if value == "solid" { RoundedRectangle(cornerRadius: 1).frame(width: 14, height: 14) }
            else {
                Path { path in
                    for x in stride(from: -14.0, through: 28, by: 4) {
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x + 14, y: 14))
                        if value == "crosshatch" { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x - 14, y: 14)) }
                    }
                }.stroke(lineWidth: 1).frame(width: 14, height: 14).clipped()
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(lineWidth: 1))
            }
        case "Font family":
            Image(systemName: value == "handwritten" ? "pencil" : value == "code" ? "chevron.left.forwardslash.chevron.right" : "character")
        case "Text align":
            Image(systemName: value == "left" ? "text.alignleft" : value == "right" ? "text.alignright" : "text.aligncenter")
        default: Text(value)
        }
    }
}

enum EaselSketch {
    /// Deterministic curve perturbations keep the sketch stable between renders.
    static func path(_ path: Path, roughness: Double, pass: Int = 0) -> Path {
        guard roughness > 0 else { return path }
        var output = Path(), start = CGPoint.zero, current = CGPoint.zero, index = 0
        func jitter(_ point: CGPoint) -> CGPoint {
            index += 1
            let phase = Double(index * 7 + pass * 13)
            return CGPoint(x: point.x + sin(phase) * roughness * 0.3, y: point.y + cos(phase * 1.7) * roughness * 0.3)
        }
        path.forEach { element in
            switch element {
            case .move(let to): current = to; start = to; output.move(to: jitter(to))
            case .line(let to):
                let middle = CGPoint(x: (current.x + to.x) / 2, y: (current.y + to.y) / 2)
                output.addQuadCurve(to: jitter(to), control: jitter(middle)); current = to
            case .quadCurve(let to, let control): output.addQuadCurve(to: jitter(to), control: jitter(control)); current = to
            case .curve(let to, let control1, let control2):
                output.addCurve(to: jitter(to), control1: jitter(control1), control2: jitter(control2)); current = to
            case .closeSubpath:
                let middle = CGPoint(x: (current.x + start.x) / 2, y: (current.y + start.y) / 2)
                output.addQuadCurve(to: jitter(start), control: jitter(middle)); output.closeSubpath()
            }
        }
        return output
    }
}
