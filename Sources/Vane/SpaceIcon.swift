import AppKit
import SwiftUI

/// Space icon strings keep the existing SF Symbol format and also accept emoji.
/// The same renderer serves the sidebar, Library, search and native footer artwork.
struct SpaceIcon: View {
    let icon: String
    var filledCloud = false

    init(_ icon: String, filledCloud: Bool = false) {
        self.icon = icon
        self.filledCloud = filledCloud
    }

    var body: some View {
        if icon.allSatisfy(\.isASCII) {
            Image(systemName: filledCloud && icon == "cloud" ? "cloud.fill" : icon)
        } else {
            Text(verbatim: icon)
        }
    }
}

extension Spaces {
    /// One extended grapheme, including joined emoji, flags and variation selectors.
    static func emojiIcon(_ input: String) -> String? {
        guard let first = input.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = first.unicodeScalars
        let explicitEmoji = scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
        guard scalars.contains(where: { $0.properties.isEmoji && ($0.value > 0x7F || explicitEmoji) }) else { return nil }
        return String(first)
    }

    @MainActor static func iconImage(_ icon: String, description: String? = nil) -> NSImage? {
        guard !icon.allSatisfy(\.isASCII) else {
            return NSImage(systemSymbolName: icon, accessibilityDescription: description)
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: 16)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.accessibilityDescription = description
        return image
    }
}
