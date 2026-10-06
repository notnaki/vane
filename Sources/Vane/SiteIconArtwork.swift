import AppKit

/// Round solid site tiles without cutting into a transparent logo's own silhouette.
@MainActor enum SiteIconArtwork {
    private static let backgrounds: NSCache<NSImage, NSNumber> = {
        let cache = NSCache<NSImage, NSNumber>()
        cache.countLimit = 128
        return cache
    }()

    static func hasOpaqueBackground(_ image: NSImage) -> Bool {
        if let cached = backgrounds.object(forKey: image) { return cached.boolValue }
        let opaque = sampleBackground(image)
        backgrounds.setObject(NSNumber(value: opaque), forKey: image)
        return opaque
    }

    private static func sampleBackground(_ image: NSImage) -> Bool {
        let size = 32
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return (0..<(size * size)).allSatisfy { bytes[$0 * 4 + 3] == 255 }
    }
}
