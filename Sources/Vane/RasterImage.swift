import AppKit

/// A single, eagerly drawn display-scale raster. Serializing a drawing-handler image
/// directly would create 1x, 2x, and 3x TIFF pages and keep its drawing inputs alive.
@MainActor enum RasterImage {
    static func make(size: NSSize, drawing: (NSRect) -> Void) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        // Keep the drawing transform uniform for fractional point sizes, with the
        // spare edge pixel that AppKit's former focused-image context provided.
        let aligned = NSSize(width: ceil(size.width * scale) / scale,
                             height: ceil(size.height * scale) / scale)
        return withoutActuallyEscaping(drawing) { draw in
            // Drain AppKit's temporary drawing representation before returning;
            // it owns the handler even after the local image leaves scope.
            autoreleasepool {
                let image = NSImage(size: aligned, flipped: false) { _ in
                    draw(NSRect(origin: .zero, size: size))
                    return true
                }
                guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return NSImage(cgImage: pixels, size: size)
            }
        }
    }
}
