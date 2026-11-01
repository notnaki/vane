import AppKit
import SwiftUI

/// Transient feedback belongs to the window where the action happened.
@MainActor final class InteractionFeedback: ObservableObject {
    @Published private(set) var copiedURL: String?
    @Published private(set) var copyStamp = UUID()
    @Published private(set) var arrivingTab: UUID?
    @Published private(set) var arrivalStamp = UUID()
    @Published private(set) var tidyRanks: [String: Int] = [:]
    @Published private(set) var tidyStamp = UUID()
    private var copyReset: Task<Void, Never>?
    private var arrivalReset: Task<Void, Never>?
    private var tidyReset: Task<Void, Never>?
    private var arrivalHighlight = true

    deinit {
        copyReset?.cancel()
        arrivalReset?.cancel()
        tidyReset?.cancel()
    }

    /// Drag placement already has a ghost and insertion preview; keep its snap sound
    /// without adding a second highlight after release. Other arrival actions retain it.
    func withoutArrivalHighlight<T>(_ body: () throws -> T) rethrows -> T {
        let previous = arrivalHighlight
        arrivalHighlight = false
        if previous {
            arrivalReset?.cancel()
            arrivalReset = nil
            arrivingTab = nil
        }
        defer { arrivalHighlight = previous }
        return try body()
    }

    func copied(_ url: URL) {
        copyReset?.cancel()
        copiedURL = url.absoluteString
        copyStamp = UUID()
        let stamp = copyStamp
        InteractionSounds.play(.copy)
        copyReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.9)) } catch { return }
            guard let self, !Task.isCancelled, copyStamp == stamp else { return }
            copiedURL = nil
            copyReset = nil
        }
    }

    func arrived(_ id: UUID) {
        InteractionSounds.play(.snap)
        guard arrivalHighlight else { return }
        arrivalReset?.cancel()
        arrivingTab = id
        arrivalStamp = UUID()
        let stamp = arrivalStamp
        arrivalReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.42)) } catch { return }
            guard let self, !Task.isCancelled, arrivalStamp == stamp else { return }
            arrivingTab = nil
            arrivalReset = nil
        }
    }

    func tidied(_ ids: [String]) {
        tidyReset?.cancel()
        tidyRanks = Dictionary(ids.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        tidyStamp = UUID()
        let stamp = tidyStamp
        InteractionSounds.play(.complete)
        tidyReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            guard let self, !Task.isCancelled, tidyStamp == stamp else { return }
            tidyRanks = [:]
            tidyReset = nil
        }
    }

    func cancelTidy() {
        tidyReset?.cancel()
        tidyReset = nil
        tidyRanks = [:]
        tidyStamp = UUID()
    }
}

/// Small, synthesized wooden ticks and soft tones; no network or audio assets.
@MainActor enum InteractionSounds {
    static let preferenceKey = "interactionSounds"
    enum Cue: CaseIterable, Hashable, Sendable { case press, copy, snap, complete }
    private static var sounds: [Cue: NSSound] = [:]
    private static var lastPlayed = Date.distantPast
    private static var lastCue: Cue?

    nonisolated static func shouldPlay(_ cue: Cue, enabled: Bool,
                                      previous: Cue?, elapsed: TimeInterval) -> Bool {
        guard enabled else { return false }
        guard let previous, elapsed <= 0.08 else { return true }
        // Confirmations supersede a pointer-down tick; duplicate cues from the same
        // drop and presses during a confirmation stay quiet.
        return cue != .press && cue != previous
    }

    static func play(_ cue: Cue) {
        guard shouldPlay(cue, enabled: UserDefaults.vane.bool(forKey: preferenceKey),
                         previous: lastCue, elapsed: Date.now.timeIntervalSince(lastPlayed)) else { return }
        if sounds[cue] == nil {
            sounds[cue] = NSSound(data: wave(for: cue))
            sounds[cue]?.volume = 0.22
        }
        guard let sound = sounds[cue] else { return }
        if Date.now.timeIntervalSince(lastPlayed) <= 0.08, let lastCue {
            sounds[lastCue]?.stop()
        }
        lastPlayed = .now
        lastCue = cue
        sound.stop()
        sound.play()
    }

    private static func wave(for cue: Cue) -> Data {
        let rate = 22_050
        let duration: Double = cue == .complete ? 0.18 : cue == .press ? 0.045 : 0.09
        let frequency: Double = switch cue {
        case .press: 520
        case .copy: 880
        case .snap: 660
        case .complete: 780
        }
        let count = Int(Double(rate) * duration)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(rate))
        word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let attack = min(t / 0.004, 1)
            let release = min((duration - t) / 0.015, 1)
            let envelope = attack * release * exp(-t / (duration * 0.3))
            let base = sin(2 * .pi * frequency * t)
            let overtone = sin(2 * .pi * frequency * 1.5 * t) * (cue == .complete ? 0.35 : 0.12)
            word(Int16((base + overtone) * envelope * 12_000))
        }
        return data
    }
}

extension InteractionSounds {
    nonisolated static func check() -> [(String, Bool)] {
        [
            ("interaction sounds are silent when disabled", Cue.allCases.allSatisfy {
                shouldPlay($0, enabled: false, previous: nil, elapsed: 1)
                    == false
            }),
            ("a copy confirmation is heard after a fast press",
             shouldPlay(.copy, enabled: true, previous: .press, elapsed: 0.02)),
            ("completion supersedes a recent press",
             shouldPlay(.complete, enabled: true, previous: .press, elapsed: 0.02)),
            ("duplicate snap cues from one drop are suppressed",
             !shouldPlay(.snap, enabled: true, previous: .snap, elapsed: 0.02)),
            ("a press does not interrupt a completion cue",
             !shouldPlay(.press, enabled: true, previous: .complete, elapsed: 0.02)),
            ("a later press is heard",
             shouldPlay(.press, enabled: true, previous: .press, elapsed: 0.2)),
            ("the first cue is heard immediately",
             shouldPlay(.press, enabled: true, previous: nil, elapsed: 0)),
        ]
    }
}

/// A prompt acknowledgement that keeps the copy button and its focus owner stable.
struct CopyLinkGlyph: View {
    let copied: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    var body: some View {
        ZStack {
            Image(systemName: "link")
                .foregroundStyle(Look.inkSecondary)
                .opacity(copied ? 0 : 1)
            Image(systemName: "checkmark")
                .foregroundStyle(Look.inkPrimary)
                .opacity(copied ? 1 : 0)
        }
            // Keep both glyphs mounted so the confirmation starts on the next frame,
            // instead of waiting for the outgoing phase of a system replacement effect.
            .animation(reduced ? nil : Look.feedback, value: copied)
            .id(reduced)
    }
}

/// Pointer feedback uses the button's own pressed state, preserving native activation.
struct TactileButtonStyle: ButtonStyle {
    var scales = true

    func makeBody(configuration: Configuration) -> some View {
        TactileButtonBody(configuration: configuration, scales: scales)
    }
}

/// Small utility controls share a steady hit target, a quiet hover fill, and the
/// same press acknowledgement as the browser chrome.
struct CompactControlStyle: ButtonStyle {
    var size: CGFloat = Look.control
    var bar = false
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var hovering = false

    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    func makeBody(configuration: Configuration) -> some View {
        TactileButtonStyle().makeBody(configuration: configuration)
            .frame(width: size, height: size)
            .contentShape(.rect)
            .opacity(enabled ? 1 : Look.dimmed)
            .background {
                RoundedRectangle(cornerRadius: Look.chipRadius)
                    .fill(enabled && (configuration.isPressed || hovering)
                          ? (bar ? chromeTheme.barSelected : chromeTheme.controlFill) : .clear)
                    .animation(reduced || configuration.isPressed || !enabled ? nil : Look.quick,
                               value: hovering)
                    // Rebuild only the paint when policy changes, settling an in-flight
                    // hover fade without replacing the button or its keyboard focus.
                    .id(reduced)
            }
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, enabled in
                if !enabled { Motion.instant { hovering = false } }
            }
            .onDisappear { hovering = false }
            .vaneMotionPolicy()
    }
}

private struct TactileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let scales: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var hovered = false
    @State private var motionSuppressed = false
    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    var body: some View {
        configuration.label
            .modifier(Feel09TactileSurface(
                scale: configuration.isPressed ? 0.97 : hovered ? 1.012 : 1,
                opacity: configuration.isPressed && enabled ? 0.8 : 1,
                motionDisabled: reduced || motionSuppressed || !enabled,
                scales: scales, pressed: configuration.isPressed && enabled))
            // The shape follows layout bounds, so pressing never shrinks the hit target.
            .contentShape(.rect)
            .animation(configuration.isPressed || reduced ? nil : .spring(duration: 0.16, bounce: 0.08),
                       value: configuration.isPressed)
            .animation(reduced ? nil : Look.feedback, value: hovered)
            .transaction {
                if reduced || motionSuppressed || configuration.isPressed || !enabled {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
            .onHover {
                if $0 && !reduced { motionSuppressed = false }
                hovered = $0
            }
            .onChange(of: reduced) { _, reduced in
                if reduced { Motion.instant { motionSuppressed = true } }
            }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && enabled {
                    Motion.instant { motionSuppressed = reduced }
                    InteractionSounds.play(.press)
                }
            }
    }
}

/// Read policy outside the interpolated values, so enabling it during a release renders
/// the final surface immediately even when the spring already targets scale/opacity 1.
private struct Feel09TactileSurface: ViewModifier, Animatable {
    nonisolated var scale: CGFloat
    nonisolated var opacity: Double
    let motionDisabled: Bool
    let scales: Bool
    let pressed: Bool

    nonisolated var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, opacity) }
        set { scale = newValue.first; opacity = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(motionDisabled || !scales ? 1 : scale)
            .opacity(motionDisabled ? (pressed ? 0.8 : 1) : opacity)
    }
}

struct TabArrivalFeedback: ViewModifier {
    @ObservedObject var feedback: InteractionFeedback
    let id: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    func body(content: Content) -> some View {
        content.modifier(Feel09FeedbackHighlight(active: feedback.arrivingTab == id,
            stamp: feedback.arrivalStamp, arrival: true, reduced: reduceMotion || batterySaver.isActive))
    }
}

struct TidyRowFeedback: ViewModifier {
    @ObservedObject var feedback: InteractionFeedback
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    func body(content: Content) -> some View {
        content.modifier(Feel09FeedbackHighlight(active: feedback.tidyRanks[id] != nil,
            stamp: feedback.tidyStamp, arrival: false, reduced: reduceMotion || batterySaver.isActive))
    }
}

/// One model clock per feedback kind, no per-row timers or delayed animation tails.
/// Repeating the same action extends its highlight instead of blinking it off and on.
struct Feel09FeedbackHighlight: ViewModifier {
    let active: Bool
    let stamp: UUID
    let arrival: Bool
    let reduced: Bool
    @State private var suppressedStamp: UUID?
    private var visible: Bool { active && !reduced && suppressedStamp != stamp }

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: Look.pillRadius)
                .fill(.tint.opacity(arrival ? 0 : 0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: Look.pillRadius)
                        .strokeBorder(.tint.opacity(arrival ? 0.6 : 0.2), lineWidth: arrival ? 1.5 : 1)
                }
                .opacity(visible ? 1 : 0)
                .animation(visible ? nil : .easeOut(duration: 0.18), value: visible)
                // Also mask an already-running fade whose target was zero before policy
                // changed. Disabling its transaction alone cannot finish that fade.
                .opacity(reduced || suppressedStamp == stamp ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .transaction {
            if reduced {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
        .onChange(of: reduced, initial: true) { _, reduced in
            if reduced { Motion.instant { suppressedStamp = stamp } }
        }
        .onChange(of: stamp) { _, stamp in
            if reduced { Motion.instant { suppressedStamp = stamp } }
        }
    }
}
