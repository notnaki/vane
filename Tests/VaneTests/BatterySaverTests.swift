import XCTest
@testable import vane

@MainActor final class BatterySaverTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "vane-battery-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAutomaticTracksBatteryAndCharger() {
        let saver = BatterySaver(defaults: defaults())
        XCTAssertEqual(saver.mode, .automatic)
        saver.update(power: .init(onBattery: true, percent: 19))
        XCTAssertTrue(saver.isActive)
        saver.update(power: .init(onBattery: false, percent: 19))
        XCTAssertFalse(saver.isActive, "Plugging in stops automatic saving")
        saver.update(power: .init(onBattery: true, percent: 21))
        XCTAssertFalse(saver.isActive)
        saver.update(power: .init(onBattery: true, percent: 20))
        XCTAssertFalse(saver.isActive, "Automatic saving starts below 20 percent")
        saver.update(power: .init(onBattery: true, percent: nil))
        XCTAssertFalse(saver.isActive, "Unknown battery information cannot activate saving")
    }

    func testOffAndAlwaysOnPersistAndApplyImmediately() {
        let prefs = defaults()
        let saver = BatterySaver(defaults: prefs)
        saver.update(power: .init(onBattery: true, percent: 5))
        XCTAssertTrue(saver.isActive)
        saver.setMode(.off)
        XCTAssertFalse(saver.isActive)
        XCTAssertEqual(BatterySaver(defaults: prefs).mode, .off)
        saver.update(power: .init(onBattery: true, percent: 1))
        XCTAssertFalse(saver.isActive, "A later power notification must respect Off")
        saver.setMode(.alwaysOn)
        XCTAssertTrue(saver.isActive)
        saver.update(power: .init(onBattery: false, percent: nil))
        XCTAssertTrue(saver.isActive, "Always On also works on a desktop")
        let relaunched = BatterySaver(defaults: prefs)
        XCTAssertEqual(relaunched.mode, .alwaysOn)
        XCTAssertTrue(relaunched.isActive)
        saver.setMode(.automatic)
        XCTAssertFalse(saver.isActive)
    }

    func testBatterySavingShortensIdleClockWithoutWeakeningProtections() {
        XCTAssertEqual(BatterySaver.idleLimit(normal: 1800, saving: true), 300)
        XCTAssertEqual(BatterySaver.idleLimit(normal: 60, saving: true), 60)
        XCTAssertEqual(BatterySaver.idleLimit(normal: 1800, saving: false), 1800)
        let limit = BatterySaver.idleLimit(normal: 1800, saving: true)
        let idle = Suspension.Facts(idle: 301)
        XCTAssertTrue(Suspension.shouldSuspend(idle, after: limit))
        for protected in [\Suspension.Facts.active, \.pinned, \.isPrivate,
                          \.playing, \.loading, \.hasInput] {
            var facts = idle
            facts[keyPath: protected] = true
            XCTAssertFalse(Suspension.shouldSuspend(facts, after: limit))
        }
    }

    func testPowerSourceDecodingRejectsAccessoriesAndInvalidCapacity() {
        var battery: [String: Any] = ["Type": "InternalBattery", "Is Present": true,
            "Power Source State": "Battery Power", "Current Capacity": NSNumber(value: 38),
            "Max Capacity": NSNumber(value: 200)]
        let decoded = BatterySaver.Power.decode([battery])
        XCTAssertTrue(decoded.onBattery)
        XCTAssertEqual(decoded.percent, 19)
        battery["Power Source State"] = "AC Power"
        XCTAssertFalse(BatterySaver.Power.decode([battery]).onBattery)
        battery["Max Capacity"] = 0
        XCTAssertNil(BatterySaver.Power.decode([battery]).percent)
        battery["Is Present"] = false
        XCTAssertNil(BatterySaver.Power.decode([battery]).percent)
        XCTAssertFalse(BatterySaver.Power.decode([]).onBattery)
        XCTAssertNil(BatterySaver.Power.decode([["Type": "UPS", "Current Capacity": 1,
            "Max Capacity": 100, "Power Source State": "Battery Power"]]).percent)
    }

    func testNoticeOnlyAppearsForActivationChanges() throws {
        let saver = BatterySaver(defaults: defaults())
        XCTAssertNil(saver.notice, "A new window must not announce an inactive mode")
        saver.update(power: .init(onBattery: true, percent: 10))
        let activated = try XCTUnwrap(saver.notice)
        XCTAssertTrue(activated.isActive)
        saver.update(power: .init(onBattery: true, percent: 9))
        XCTAssertEqual(saver.notice?.id, activated.id, "Repeated battery readings must not restart the popup")
        saver.setMode(.off)
        let deactivated = try XCTUnwrap(saver.notice)
        XCTAssertFalse(deactivated.isActive)
        XCTAssertNotEqual(deactivated.id, activated.id)
        saver.dismissNotice(activated.id)
        XCTAssertEqual(saver.notice?.id, deactivated.id, "A stale dismissal must not remove newer news")
        saver.dismissNotice(deactivated.id)
        XCTAssertNil(saver.notice)
        saver.update(power: .init(onBattery: false, percent: 9))
        XCTAssertNil(saver.notice, "An unchanged state must not bring the popup back")
    }

    func testNoticeExpiresWithoutChangingBatterySaving() async throws {
        let saver = BatterySaver(defaults: defaults(), noticeDuration: .milliseconds(40))
        saver.setMode(.alwaysOn)
        XCTAssertNotNil(saver.notice)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertNil(saver.notice)
        XCTAssertTrue(saver.isActive, "Dismissing the notification must not turn saving off")
    }

    func testHoverInAnyWindowHoldsNoticeUntilAllPointersLeave() async throws {
        let saver = BatterySaver(defaults: defaults(), noticeDuration: .milliseconds(40))
        saver.setMode(.alwaysOn)
        let firstWindow = UUID(), secondWindow = UUID()
        saver.holdNotice(true, by: firstWindow)
        saver.holdNotice(true, by: secondWindow)
        saver.holdNotice(false, by: firstWindow)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertNotNil(saver.notice)
        saver.holdNotice(false, by: secondWindow)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertNil(saver.notice)
    }

    func testReplacementGetsItsOwnExpiryEvenWhenOldTimerWasRunning() async throws {
        let saver = BatterySaver(defaults: defaults(), noticeDuration: .milliseconds(200))
        saver.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(140))
        saver.setMode(.off)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(saver.notice?.isActive, false, "The old activation clock cannot dismiss deactivation")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(saver.notice)
    }
}
