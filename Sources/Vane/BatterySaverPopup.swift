import SwiftUI

/// A temporary browser notice, inside the page's top-right corner. The separate
/// setting pill and lightning glyph match the battery-saver reference.
struct BatterySaverPopup: View {
    let notice: BatterySaver.Notice
    @ObservedObject var saver: BatterySaver
    @State private var host = UUID()

    private let green = Color(red: 0.13, green: 0.30, blue: 0.13)
    private let buttonGreen = Color(red: 0.18, green: 0.43, blue: 0.19)

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
                Text(notice.text)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(green, in: .rect(cornerRadius: 12))

            Button {
                saver.dismissNotice(notice.id)
                SettingsWindow.show(tab: "advanced")
            } label: {
                HStack(spacing: 6) {
                    Text("Edit this setting")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(buttonGreen, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .accessibilityHint("Open Battery Saver in Advanced settings")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 320, alignment: .trailing)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .onHover { saver.holdNotice($0, by: host) }
        .onDisappear { saver.holdNotice(false, by: host) }
    }
}
