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

    func copied(_ url: URL) {
        copyReset?.cancel()
        copiedURL = url.absoluteString
        copyStamp = UUID()
        InteractionSounds.play(.copy)
        copyReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            self?.copiedURL = nil
        }
    }

    func arrived(_ id: UUID) {
        arrivalReset?.cancel()
        arrivingTab = id
        arrivalStamp = UUID()
        InteractionSounds.play(.snap)
        arrivalReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.65)) } catch { return }
            self?.arrivingTab = nil
        }
    }

    func tidied(_ ids: [String]) {
        tidyReset?.cancel()
        tidyRanks = Dictionary(ids.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        tidyStamp = UUID()
        InteractionSounds.play(.complete)
        tidyReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.8)) } catch { return }
            self?.tidyRanks = [:]
        }
    }

    func cancelTidy() {
        tidyReset?.cancel()
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

/// Pointer feedback uses the button's own pressed state, preserving native activation.
struct TactileButtonStyle: ButtonStyle {
    var scales = true

    func makeBody(configuration: Configuration) -> some View {
        TactileButtonBody(configuration: configuration, scales: scales)
    }
}

private struct TactileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let scales: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var hovered = false
    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    var body: some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(reduced || !enabled || !scales ? 1 : configuration.isPressed ? 0.96 : hovered ? 1.025 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(reduced ? nil : .spring(duration: 0.18, bounce: 0.18),
                       value: configuration.isPressed)
            .animation(reduced ? nil : Look.quick, value: hovered)
            .onHover { hovered = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed && enabled { InteractionSounds.play(.press) }
            }
    }
}

struct TabArrivalFeedback: ViewModifier {
    @ObservedObject var feedback: InteractionFeedback
    let id: UUID
    @State private var visible = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: Look.pillRadius)
                .strokeBorder(.tint.opacity(visible ? 0.65 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task(id: feedback.arrivalStamp) {
            guard feedback.arrivingTab == id else { return }
            visible = true
            do { try await Task.sleep(for: .seconds(0.12)) } catch { return }
            withAnimation(.easeOut(duration: 0.4)) { visible = false }
        }
        .onChange(of: feedback.arrivingTab) { _, tab in
            if tab != id { visible = false }
        }
    }
}

struct TidyRowFeedback: ViewModifier {
    @ObservedObject var feedback: InteractionFeedback
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = true

    func body(content: Content) -> some View {
        content
            .opacity(settled || reduceMotion ? 1 : 0.55)
            .offset(x: settled || reduceMotion ? 0 : -8)
            .task(id: feedback.tidyStamp) {
                guard let rank = feedback.tidyRanks[id], !reduceMotion else {
                    settled = true
                    return
                }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { settled = false }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.26, bounce: 0.16)
                    .delay(min(Double(rank) * 0.025, 0.18))) { settled = true }
            }
    }
}
