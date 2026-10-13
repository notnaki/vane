import AppKit
import ImageIO

/// Serial decoding prevents a large Media collection from flooding the worker pool.
actor Feel05ThumbnailLoader {
    struct Result: @unchecked Sendable {
        // The freshly decoded image is handed to the main actor; it is never mutated here.
        let image: NSImage?
        let signature: String
        let bytes: Int
        let unchanged: Bool
    }

    private var cancelled: Result { Result(image: nil, signature: "", bytes: 0, unchanged: true) }

    func load(_ url: URL, knownSignature: String?) -> Result {
        guard !Task.isCancelled else { return cancelled }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try? freshURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        let signature = values.map {
            "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0)|\($0.fileSize ?? 0)|\(String(describing: $0.fileResourceIdentifier))"
        } ?? "missing"
        if signature == knownSignature {
            return Result(image: nil, signature: signature, bytes: 0, unchanged: true)
        }
        guard !Task.isCancelled else { return cancelled }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Look.mediaPixels,
              ] as CFDictionary) else {
            return Result(image: nil, signature: signature, bytes: 0, unchanged: false)
        }
        return Result(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
                      signature: signature, bytes: cg.width * cg.height * 4, unchanged: false)
    }
}
