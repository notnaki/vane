import AppKit
import Combine
import IOKit.ps

@MainActor final class BatterySaver: ObservableObject {
    static let key = "batterySaverMode"
    static let shared = BatterySaver(defaults: .vane, onActivation: {
        Previews.shared.cancel()
        Suspension.sweep()
    })

    enum Mode: String, CaseIterable {
        case off, automatic, alwaysOn
        var title: String {
            switch self {
            case .off: "Off"
            case .automatic: "Automatic"
            case .alwaysOn: "Always On"
            }
        }
    }

    struct Power {
        var onBattery = false
        var percent: Double?

        /// Only the Mac's internal battery counts, never a UPS or wireless accessory.
        /// Missing or invalid capacity stays unknown, rather than looking like 0%.
        nonisolated static func decode(_ descriptions: [[String: Any]]) -> Power {
            guard let battery = descriptions.first(where: {
                $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType &&
                $0[kIOPSIsPresentKey] as? Bool != false
            }) else { return Power() }
            let onBattery = battery[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = battery[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = battery[kIOPSMaxCapacityKey] as? Double,
                  current.isFinite, maximum.isFinite,
                  current >= 0, maximum > 0, current <= maximum else {
                return Power(onBattery: onBattery)
            }
            return Power(onBattery: onBattery, percent: current / maximum * 100)
        }

        nonisolated static func read() -> Power {
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
            else { return Power() }
            let descriptions = sources.compactMap {
                IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
            }
            return decode(descriptions)
        }
    }

    @Published private(set) var mode: Mode
    @Published private(set) var isActive: Bool
    struct Notice: Identifiable {
        let id = UUID()
        let isActive: Bool
        var text: String { "Battery Saver Mode \(isActive ? "Activated" : "Deactivated")" }
    }
    @Published private(set) var notice: Notice?
    private let defaults: UserDefaults
    private var power = Power()
    private let onActivation: () -> Void
    private var source: CFRunLoopSource?
    private var started = false
    private let noticeDuration: Duration
    private var noticeTimer: Task<Void, Never>?
    private var noticeHolds: Set<UUID> = []

    init(defaults: UserDefaults, noticeDuration: Duration = .seconds(4),
         onActivation: @escaping () -> Void = {}) {
        self.defaults = defaults
        self.noticeDuration = noticeDuration
        self.onActivation = onActivation
        let mode = Mode(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .automatic
        self.mode = mode
        isActive = Self.shouldSave(mode: mode, power: Power())
    }

    deinit { noticeTimer?.cancel() }

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        defaults.set(mode.rawValue, forKey: Self.key)
        self.mode = mode
        apply()
    }

    func update(power: Power) {
        self.power = power
        apply()
    }

    private func apply() {
        let active = Self.shouldSave(mode: mode, power: power)
        guard active != isActive else { return }
        isActive = active
        noticeHolds.removeAll()
        notice = Notice(isActive: active)
        scheduleNotice()
        if active { onActivation() }
    }

    /// One app-wide notice with a fresh identity and clock for each state transition.
    /// A window opened later sees only news that has not yet expired.
    func dismissNotice(_ id: UUID) {
        guard notice?.id == id else { return }
        noticeTimer?.cancel()
        noticeTimer = nil
        noticeHolds.removeAll()
        notice = nil
    }

    /// Keep the setting button still while a pointer is reaching for it. Track hosts
    /// separately so closing or leaving one window cannot release another's hold.
    func holdNotice(_ held: Bool, by host: UUID) {
        if held {
            noticeHolds.insert(host)
            noticeTimer?.cancel()
        } else if noticeHolds.remove(host) != nil {
            scheduleNotice()
        }
    }

    private func scheduleNotice() {
        noticeTimer?.cancel()
        guard noticeHolds.isEmpty, let id = notice?.id else { return }
        let duration = noticeDuration
        noticeTimer = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismissNotice(id)
        }
    }

    nonisolated static func shouldSave(mode: Mode, power: Power) -> Bool {
        switch mode {
        case .off: return false
        case .alwaysOn: return true
        case .automatic:
            guard power.onBattery, let percent = power.percent,
                  percent.isFinite, percent >= 0, percent <= 100 else { return false }
            return percent < 20
        }
    }

    /// Saving must not lengthen an already shorter user-selected idle timeout.
    nonisolated static func idleLimit(normal: TimeInterval, saving: Bool) -> TimeInterval {
        saving ? min(normal, 5 * 60) : normal
    }

    /// Battery/charger notifications arrive on the main run loop; no extra polling timer.
    /// The ordinary suspension sweep also refreshes if notification registration fails.
    func begin() {
        guard !started else { return }
        started = true
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatterySaver.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        refresh()
    }

    func refresh() { update(power: Power.read()) }

    nonisolated static func check() -> [(String, Bool)] {
        [
            ("automatic saving starts below 20% on battery",
             shouldSave(mode: .automatic, power: Power(onBattery: true, percent: 19))),
            ("charging a low battery does not activate automatic saving",
             !shouldSave(mode: .automatic, power: Power(onBattery: false, percent: 5))),
            ("20% and higher do not activate automatic saving",
             [20.0, 21, 100].allSatisfy {
                 !shouldSave(mode: .automatic, power: Power(onBattery: true, percent: $0))
             }),
            ("unknown or invalid battery data does not activate automatic saving",
             [nil, -1, 101, Double.nan, Double.infinity].allSatisfy {
                 !shouldSave(mode: .automatic, power: Power(onBattery: true, percent: $0))
             }),
            ("Off respects the user's choice even on an empty battery",
             !shouldSave(mode: .off, power: Power(onBattery: true, percent: 0))),
            ("Always On works without a battery", shouldSave(mode: .alwaysOn, power: Power())),
            ("saving caps a long idle timeout at five minutes",
             idleLimit(normal: 1800, saving: true) == 300),
            ("saving preserves a shorter timeout", idleLimit(normal: 60, saving: true) == 60),
            ("stopping saving restores the normal idle timeout",
             idleLimit(normal: 1800, saving: false) == 1800),
        ]
    }
}
