import SwiftUI
import AppKit

/// A capture can be trimmed after collecting it, without giving up its source link.
struct EaselCrop: View {
    let data: Data
    let apply: (Data) -> Void
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    var body: some View {
        if let image = NSImage(data: data) {
            let scale = min(380 / image.size.width, 230 / image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            VStack(alignment: .leading, spacing: 10) {
                Text("Drag over the image to choose a crop.").font(.caption).foregroundStyle(.secondary)
                Image(nsImage: image).resizable().frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        if let rect = selection(width: width, height: height) {
                            Rectangle().fill(.blue.opacity(0.12)).overlay(Rectangle().stroke(.blue, lineWidth: 2))
                                .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { start = $0.startLocation; end = $0.location })
                Button("Crop Image") {
                    guard let rect = selection(width: width, height: height), rect.width > 4, rect.height > 4,
                          let source = NSBitmapImageRep(data: data)?.cgImage else { return }
                    let pixels = CGRect(x: rect.minX / width * Double(source.width), y: rect.minY / height * Double(source.height),
                                        width: rect.width / width * Double(source.width), height: rect.height / height * Double(source.height))
                    guard let cropped = source.cropping(to: pixels.integral),
                          let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { return }
                    apply(png); start = nil; end = nil
                }.disabled(start == nil || end == nil)
            }
        }
    }
    private func selection(width: Double, height: Double) -> CGRect? {
        guard let start, let end else { return nil }
        let x = min(max(0, min(start.x, end.x)), width)
        let y = min(max(0, min(start.y, end.y)), height)
        return CGRect(x: x, y: y, width: max(0, min(width, max(start.x, end.x)) - x),
                      height: max(0, min(height, max(start.y, end.y)) - y))
    }
}
