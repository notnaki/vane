import SwiftUI

/// Shared by browser windows and Profiles settings. Unlike a toast, an unsaved profile
/// warning stays until the latest edits reach disk, including in windows opened later.
struct ProfileSaveNotice: View {
    @ObservedObject var manager: ProfileManager

    var body: some View {
        VStack(spacing: Look.inset) {
            ForEach(manager.saveFailures) { failure in
                ProfileSaveFailureCard(manager: manager, failure: failure)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 380)
    }
}

private struct ProfileSaveFailureCard: View {
    @ObservedObject var manager: ProfileManager
    let failure: ProfileManager.SaveFailure
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Look.warning)
                .frame(width: 28, height: 28)
                .background(Look.warning.opacity(0.12), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Look.inset) {
                HStack(alignment: .firstTextBaseline, spacing: Look.inset) {
                    Text(failure.title)
                        .font(Look.heading)
                        .foregroundStyle(Look.inkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if failure.id != .profiles {
                        Button { manager.dismissSaveFailure(failure.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Look.inkSecondary)
                                .frame(width: Look.chip, height: Look.chip)
                                .contentShape(.rect)
                        }
                        .buttonStyle(TactileButtonStyle(scales: false))
                        .accessibilityLabel("Dismiss \(failure.title)")
                    }
                }

                Text(failure.message)
                    .font(Look.footnote)
                    .foregroundStyle(Look.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Look.inset) { actions }
                    VStack(alignment: .leading, spacing: Look.inset) { actions }
                }
                .padding(.top, 2)

                if let details = failure.details {
                    DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                        Text(details)
                            .font(Look.caption)
                            .foregroundStyle(Look.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(Look.caption)
                    .foregroundStyle(Look.inkSecondary)
                    .tint(Look.inkSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: Look.pillRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Look.pillRadius)
                .strokeBorder(Look.cardStroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: detailsExpanded)
    }

    @ViewBuilder private var actions: some View {
        if failure.canRetry {
            RecoveryAction("Retry Save", symbol: "arrow.clockwise", primary: true) {
                manager.retryProfileSave()
            }
        }
        RecoveryAction("Data Folder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([manager.directory])
        }
        .accessibilityLabel("Show Data Folder")
    }
}

private struct RecoveryAction: View {
    let title: String
    let symbol: String
    var primary = false
    let run: () -> Void
    @State private var hovered = false
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String, primary: Bool = false, run: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.run = run
    }

    var body: some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(Look.footnote.weight(primary ? .semibold : .medium))
                .foregroundStyle(primary ? Look.inkPrimary : Look.inkSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(primary ? Look.warning.opacity(hovered ? 0.22 : 0.15)
                            : hovered ? Look.hovered : .clear,
                            in: .rect(cornerRadius: Look.chipRadius))
                .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle(scales: false))
        .onHover { hovered = $0 }
        .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick, value: hovered)
    }
}
