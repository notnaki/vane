import SwiftUI

/// Library image requests belong to the visible view's cancellable task, including
/// cache hits that need file-signature validation when a row reappears.
struct Feel05DownloadThumbnail: View {
    @ObservedObject var item: Downloads.Item
    @ObservedObject private var thumbnails = Thumbnails.shared

    var body: some View {
        Group {
            if item.status == .done, let url = item.url, Library.isImage(name: item.name) {
                Group {
                    if let image = thumbnails.image(for: url) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo").foregroundStyle(Look.inkQuiet)
                    }
                }
                .frame(width: Look.libraryThumb, height: Look.libraryThumb)
                .clipShape(.rect(cornerRadius: Look.captionGap))
                .task(id: url) { await thumbnails.requestVisible(url) }
            } else {
                DownloadIcon(item: item)
            }
        }
        .accessibilityHidden(true)
    }
}
