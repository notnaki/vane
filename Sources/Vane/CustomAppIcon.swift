import AppKit
import UniformTypeIdentifiers

/// A custom Dock icon lives with the user's data; the signed app bundle stays intact.
@MainActor enum CustomAppIcon {
    static let name = "Custom"
    private static var file: URL { Store.directory.appendingPathComponent("custom-app-icon") }
    static var custom: NSImage? { NSImage(contentsOf: file) }

    /// Copy the chosen image while its sandbox grant is valid, so it survives relaunches.
    static func choose() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose a Vane Icon"
        panel.prompt = "Choose Icon"
        panel.message = "Choose an image for Vane’s Dock icon. A square image works best."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw IconError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw IconError.unreadable
        }
        try data.write(to: file, options: .atomic)
        AppIcon.apply(name)
        return true
    }

    enum IconError: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose an image smaller than 20 MB."
            case .unreadable: "Vane couldn’t read that image. Try a PNG, JPEG, TIFF, or ICNS file."
            }
        }
    }
}
