import SwiftUI

/// Cumulative streams may append, revise, or retract. Reveal whole graphemes,
/// preserve only verified prefixes, and bound the artificial delay for a backlog.
struct LinkPreviewTextReveal {
    private(set) var target = ""
    private(set) var visible = ""

    var pending: Bool { visible != target }

    mutating func retarget(_ text: String, immediately: Bool) {
        target = text
        if immediately { visible = text }
        else if !text.hasPrefix(visible) { visible = "" }
    }

    mutating func advance() {
        let remaining = target.count - visible.count
        guard remaining > 0 else { return }
        let step = max(1, (remaining + 23) / 24)
        visible = String(target.prefix(min(target.count, visible.count + step)))
    }
}

struct LinkPreviewAnimatedCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var battery = BatterySaver.shared
    @State private var reveal = LinkPreviewTextReveal()
    let preview: Previews.Preview
    let size: CGSize

    private struct RevealKey: Equatable {
        var text: String
        var immediate: Bool
    }

    private var key: RevealKey {
        RevealKey(text: preview.summary.isEmpty ? preview.description : preview.summary,
                  immediate: reduceMotion || Motion.reduced || battery.isActive)
    }

    var body: some View {
        LinkPreviewCard(preview: preview, size: size, revealedText: key.immediate ? key.text : reveal.visible)
            .animation(key.immediate ? nil : Look.quick, value: reveal.visible)
            .animation(key.immediate ? nil : Look.quick, value: preview.image != nil)
            .task(id: key) {
                reveal.retarget(key.text, immediately: key.immediate)
                while reveal.pending {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard !Task.isCancelled else { return }
                    reveal.advance()
                }
            }
            .vaneMotionPolicy()
    }
}
