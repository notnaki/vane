import XCTest
@testable import vane

final class ThemeWheelTests: XCTestCase {
    func testReopeningMidGrayUsesTheMiddleOfItsOwnLightnessRange() {
        let point = Spaces.themePoint(hex: "#808080")!
        XCTAssertEqual(point.x, 0.75, accuracy: 0.002)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.002)
    }
}

extension ThemeWheelTests {
    func testBlackAndWhiteHaveClippedLightnessRangesAndStayNeutral() {
        let black = ThemeWheel(ThemeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(black.lower, 0)
        XCTAssertEqual(black.upper, 0.25)
        let gray = black.color(at: CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(gray.red, 0.125, accuracy: 1e-9)
        XCTAssertEqual(gray.red, gray.green)
        XCTAssertEqual(gray.green, gray.blue)
        let white = ThemeWheel(ThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(white.lower, 0.75)
        XCTAssertEqual(white.upper, 1)
    }

    func testDragUsesTheOpeningRangeWithoutRecalibratingOrLosingSaturation() {
        let primary = ThemeColor.hsl(h: 0, s: 2.0 / 3, l: 0.65)
        let wheel = ThemeWheel(primary)
        let outside = wheel.color(at: CGPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(outside.hsl.l, 0.8, accuracy: 1e-9)
        XCTAssertEqual(outside.hsl.s, primary.hsl.s, accuracy: 1e-9)
        XCTAssertEqual(wheel.point(outside).x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(wheel.color(at: wheel.point(primary)).hsl.l, 0.65, accuracy: 1e-9)
        XCTAssertNotEqual(ThemeWheel(outside).lower, wheel.lower)
    }

    func testHueRunsClockwiseAndCenterKeepsTheHueItArrivedWith() {
        let wheel = ThemeWheel(.hsl(h: 0, s: 0.6, l: 0.5))
        XCTAssertEqual(wheel.color(at: CGPoint(x: 0.5, y: 0.75)).hsl.h, 0.25, accuracy: 1e-9)
        XCTAssertEqual(wheel.color(at: CGPoint(x: 0.25, y: 0.5)).hsl.h, 0.5, accuracy: 1e-9)
        XCTAssertEqual(wheel.color(at: CGPoint(x: 0.5, y: 0.25)).hsl.h, 0.75, accuracy: 1e-9)
        XCTAssertEqual(wheel.color(at: CGPoint(x: 0.5, y: 0.5), hueAtCenter: 0.3).hsl.h, 0.3, accuracy: 1e-9)
    }

    func testIntensityHasFixedTravelAndChangesTheEntireWash() {
        XCTAssertEqual(ThemeIntensity.x(value: 0.8, width: 224), 454.4 - 280, accuracy: 1e-9)
        XCTAssertEqual(ThemeIntensity.value(x: 112, width: 224), 0.5)
        XCTAssertEqual(ThemeIntensity.value(x: 0, width: 224), 0)
        XCTAssertEqual(ThemeIntensity.value(x: 224, width: 224), 1)
        XCTAssertEqual(ThemeIntensity.thumb(0), CGSize(width: 12, height: 48))
        XCTAssertEqual(ThemeIntensity.thumb(1), CGSize(width: 28, height: 64))
        let color = ThemeColor(red: 1, green: 0.2, blue: 0.1)
        XCTAssertEqual(color.ground(strength: 0), ThemeColor(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(color.ground(strength: 1).red, color.red)
        XCTAssertEqual(color.ground(strength: 0.5).red, 0.75)
    }

    func testP3PaletteSurvivesPersistenceAndLegacyChangesInvalidateIt() throws {
        var space = Space(name: "Theme", profileID: UUID())
        let green = ThemeColor(red: 0, green: 1, blue: 0)
        Spaces.setPalette([green], on: &space)
        let restored = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(Spaces.palette(of: restored), [green])
        XCTAssertEqual(restored.colorHex, green.hex)
        Spaces.setThemeColors(["#808080"], on: &space)
        XCTAssertNil(space.themePalette)
        XCTAssertEqual(Spaces.palette(of: space), [ThemeColor(hex: "#808080")!])
    }

    func testNeutralAndEndpointDragsKeepGeometryIndependentlyOfHue() {
        let target = CGPoint(x: 0.25, y: 0.5)
        let wheel = ThemeWheel(ThemeColor(red: 0.5, green: 0.5, blue: 0.5))
        let points = ThemeWheel.positions(dragged: target, index: 1, count: 3)
        XCTAssertEqual(points[1].x, target.x, accuracy: 1e-9)
        XCTAssertEqual(points[1].y, target.y, accuracy: 1e-9)
        XCTAssertEqual(wheel.color(at: points[0]).hsl.s, 0)
        let dark = ThemeWheel.positions(dragged: CGPoint(x: 0.5, y: 0.25), index: 0, count: 1)
        XCTAssertEqual(dark[0].x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(dark[0].y, 0.25, accuracy: 1e-9)
    }

    func testRimGrabPreservesModelPositionUntilPointerMoves() {
        let model = CGPoint(x: 1, y: 0.5), start = CGPoint(x: 318, y: 170)
        let field = CGRect(x: 0, y: 0, width: 340, height: 340)
        XCTAssertEqual(ThemeWheel.dragPoint(start: start, location: start, model: model, field: field), model)
        let moved = ThemeWheel.dragPoint(start: start, location: CGPoint(x: 284, y: 170), model: model, field: field)
        XCTAssertEqual(moved.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(ThemeIntensity.width, 224)
    }

    func testCompanionsAreRebuiltAroundOnePrimaryColor() {
        let primary = ThemeColor.hsl(h: 0.05, s: 0.6, l: 0.65)
        let two = ThemeWheel.palette(primary, count: 2)
        XCTAssertEqual(two[1].hsl.h, 0.55, accuracy: 1e-9)
        let three = ThemeWheel.palette(primary, count: 3)
        XCTAssertEqual(three[1].hsl.h, 0.05 + 5.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(three[2].hsl.h, 1.05 - 5.0 / 12, accuracy: 1e-9)
        for color in three { XCTAssertEqual(color.hsl.s, primary.hsl.s, accuracy: 1e-9); XCTAssertEqual(color.hsl.l, primary.hsl.l, accuracy: 1e-9) }
    }
}
