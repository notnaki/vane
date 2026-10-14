import Foundation

struct ThemePreset: Identifiable, Sendable {
    let id: String
    let name: String
    let colors: [ThemeColor]

    func matches(_ palette: [ThemeColor]) -> Bool {
        colors.count == palette.count && zip(colors, palette).allSatisfy { a, b in
            a.hex == b.hex || max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) < 1e-5
        }
    }

    static let all: [ThemePreset] = {
        let singles = Look.themeSwatches.compactMap { hex -> ThemePreset? in
            guard let color = Look.themePresetColors[hex] else { return nil }
            return ThemePreset(id: hex, name: "Theme colour \(hex)", colors: [color])
        }
        let gradients = singles.prefix(9).map { single in
            ThemePreset(id: "gradient-\(single.id)", name: "Multicolour theme \(single.id)",
                        colors: ThemeWheel.palette(single.colors[0], count: 3, offsets: [0, 1.0 / 9, -1.0 / 9]))
        }
        return Array(singles.prefix(9)) + gradients + Array(singles.dropFirst(9))
    }()

    static func page(of palette: [ThemeColor]) -> Int {
        (all.firstIndex { $0.matches(palette) } ?? 0) / Look.swatchPage
    }
}
