import AppKit
import SwiftUI

/// A card owns its decoded image. Geometry/selection changes reuse it; crop/undo
/// replaces it. No process-wide cache can keep a closed profile's captures alive.
@MainActor final class Feel07EaselImage: ObservableObject {
    private(set) var data: Data?
    @Published private(set) var image: NSImage?
    init(data: Data?) { self.data = data; image = data.flatMap(NSImage.init(data:)) }
    func update(_ data: Data?) {
        guard self.data != data else { return }
        self.data = data
        image = data.flatMap(NSImage.init(data:))
    }
}

struct Feel07EaselImageView: View {
    let data: Data?
    @StateObject private var decoded: Feel07EaselImage
    init(data: Data?) {
        self.data = data
        _decoded = StateObject(wrappedValue: Feel07EaselImage(data: data))
    }
    var body: some View {
        Group {
            if let image = decoded.image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo.badge.exclamationmark") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: data) { decoded.update(data) }
    }
}
