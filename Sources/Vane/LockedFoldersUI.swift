import SwiftUI
import CoreImage.CIFilterBuiltins

/// Only a frozen, heavily obscured image is drawn behind the unlock control. The live
/// WebView has already been released, so it cannot receive clicks, focus, or accessibility.
struct LockedFolderPage: View {
    @EnvironmentObject var store: TabStore
    let folder: Folder
    @State private var authenticating = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(nsColor: Look.pageGround)
            if let image = store.lockedFolderBackdrop {
                Image(nsImage: image).resizable().scaledToFill()
                    .blur(radius: 28, opaque: true)
                    .overlay(Color(nsColor: Look.pageGround).opacity(0.5))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(Look.inkSecondary)
                    .accessibilityHidden(true)
                Text("Folder locked").font(.system(size: 22, weight: .semibold))
                Text("Unlock “\(folder.name)” to view this page and its tabs.")
                    .font(Look.text).foregroundStyle(Look.inkSecondary)
                    .multilineTextAlignment(.center)
                Button(authenticating ? "Unlocking…" : "Unlock Folder") {
                    authenticating = true
                    failed = false
                    store.unlockFolder(folder.id) { success in
                        authenticating = false
                        failed = !success
                        if success, let current = store.current { store.current = current }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(authenticating)
                Text(failed ? "Folder remains locked. Try again when you’re ready."
                           : "Use Touch ID or your Mac password.")
                    .font(Look.caption).foregroundStyle(Look.inkTertiary)
            }
            .padding(32)
            .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}

@MainActor enum LockedFolderBackdrop {
    /// Downsample before blurring so text is never retained at readable resolution.
    static func capture(_ tab: Tab) -> NSImage? {
        let source: NSImage?
        if let snapshot = tab.windowSnapshot {
            source = snapshot
        } else if let web = tab.existingWeb, !web.bounds.isEmpty,
                  let bitmap = web.bitmapImageRepForCachingDisplay(in: web.bounds) {
            web.cacheDisplay(in: web.bounds, to: bitmap)
            let image = NSImage(size: web.bounds.size)
            image.addRepresentation(bitmap)
            source = image
        } else {
            source = nil
        }
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }
        let size = NSSize(width: 32, height: max(1, 32 * source.size.height / source.size.width))
        let small = NSImage(size: size)
        small.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let data = small.tiffRepresentation, let input = CIImage(data: data) else { return nil }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 3
        guard let output = blur.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: source.size)
    }
}
