import SwiftUI

@MainActor extension ImageRenderer {
    /// `cgImage` and `nsImage` rasterize on RenderBox's shared Metal device. When that GPU
    /// stalls or resets (CI's paravirtual GPU does so for seconds at a time) they return a
    /// correctly sized, fully transparent image without any error. Drawing the same display
    /// list into a CPU bitmap never touches Metal, so artwork cannot silently come out blank.
    var cpuImage: CGImage? {
        var image: CGImage?
        let scale = scale
        render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            draw(context)
            image = context.makeImage()
        }
        return image
    }
}
