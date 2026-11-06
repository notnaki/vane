import SwiftUI

/// A call status, not a recording indicator. Its spoken label makes that distinction.
struct MeetCallIndicator: View {
    var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating,
                              isActive: animate && !reduceMotion && !batterySaver.isActive)
                .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 0.75) }
                .frame(width: 7, height: 7)
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In a Google Meet call")
        .help("In a Google Meet call")
    }
}
