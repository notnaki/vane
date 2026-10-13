import SwiftUI

/// The shared DownloadIcon asks for a thumbnail only while showing its fallback.
/// Library rows must also validate cache hits when they become visible again.
struct Feel05DownloadThumbnail: View {
    @ObservedObject var item: Downloads.Item

    var body: some View {
        DownloadIcon(item: item)
            .task(id: item.status == .done ? item.url : nil) {
                guard item.status == .done, let url = item.url,
                      Library.isImage(name: item.name) else { return }
                await Thumbnails.shared.requestVisible(url)
            }
    }
}
