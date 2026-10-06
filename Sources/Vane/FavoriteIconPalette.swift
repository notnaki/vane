import AppKit

/// The site's artwork supplies the selected favourite's outline colors.
@MainActor enum FavoriteIconPalette {
    private final class Palette {
        let colors: [NSColor]
        init(_ colors: [NSColor]) { self.colors = colors }
    }
    private static let cache: NSCache<NSImage, Palette> = {
        let cache = NSCache<NSImage, Palette>()
        cache.countLimit = 128
        return cache
    }()

    static func colors(for image: NSImage?) -> [NSColor] {
        guard let image, !image.isTemplate else { return [] }
        if let palette = cache.object(forKey: image) { return palette.colors }
        let colors = sample(image)
        cache.setObject(Palette(colors), forKey: image)
        return colors
    }

    private struct Swatch {
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0, x = 0.0
    }

    /// A small raster keeps this bounded regardless of the site's original icon size.
    /// Hue buckets retain multicolor logos without turning antialiased edges into stops.
    private static func sample(_ image: NSImage) -> [NSColor] {
        let size = 24
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return [] }
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var buckets = Array(repeating: Swatch(), count: 12)
        for pixel in 0..<(size * size) {
            let offset = pixel * 4
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha >= 0.2 else { continue }
            // Unpremultiply before classifying translucent brand colors.
            let red = min(1, Double(bytes[offset]) / (255 * alpha))
            let green = min(1, Double(bytes[offset + 1]) / (255 * alpha))
            let blue = min(1, Double(bytes[offset + 2]) / (255 * alpha))
            let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            let saturation = color.saturationComponent
            guard saturation >= 0.18, color.brightnessComponent >= 0.18 else { continue }
            let bucket = min(11, Int(color.hueComponent * 12))
            let weight = alpha * saturation
            buckets[bucket].red += red * weight
            buckets[bucket].green += green * weight
            buckets[bucket].blue += blue * weight
            buckets[bucket].x += Double(pixel % size) * weight
            buckets[bucket].weight += weight
        }
        let strongest = buckets.map(\.weight).max() ?? 0
        guard strongest > 0 else { return [] }
        return buckets.enumerated()
            .filter { $0.element.weight >= strongest * 0.12 }
            .sorted { $0.element.weight == $1.element.weight
                ? $0.offset < $1.offset : $0.element.weight > $1.element.weight }
            .prefix(4)
            .sorted { $0.element.x / $0.element.weight < $1.element.x / $1.element.weight }
            .map { _, swatch in
                NSColor(srgbRed: swatch.red / swatch.weight, green: swatch.green / swatch.weight,
                        blue: swatch.blue / swatch.weight, alpha: 1)
            }
    }
}
