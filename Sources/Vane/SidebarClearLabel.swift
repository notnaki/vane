import SwiftUI

/// Shared by the live sidebar and the incoming Space preview.
struct SidebarClearLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down")
                .accessibilityHidden(true)
            Text("Clear")
        }
    }
}
