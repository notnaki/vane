import XCTest
@testable import vane

final class ThemePresetTests: XCTestCase {
    func testAnalogousPresetKeepsFortyDegreeNeighbours() {
        let primary = ThemeColor.hsl(h: 0.3, s: 0.6, l: 0.65)
        let colors = ThemeWheel.palette(primary, count: 3, offsets: [0, 1.0 / 9, -1.0 / 9])
        XCTAssertEqual(colors[1].hsl.h, 0.3 + 1.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(colors[2].hsl.h, 0.3 - 1.0 / 9, accuracy: 1e-9)
    }
}

extension ThemePresetTests {
    func testEveryGradientMatchesTheMeasuredArcPalette() {
        let expected: [[[Double]]] = [
            [[0.9444218277931213, 0.9190870523452759, 0.8967581987380981], [0.9379805326461792, 0.9444217085838318, 0.8967582583427429], [0.9444218277931213, 0.8967582583427429, 0.906204879283905]],
            [[0.9014096856117249, 0.6234707832336426, 0.7293687462806702], [0.9014096856117249, 0.7028653025627136, 0.6234707236289978], [0.8881577849388123, 0.6234707832336426, 0.9014096856117249]],
            [[0.6209163069725037, 0.45569396018981934, 0.6063726544380188], [0.6209161877632141, 0.45569396018981934, 0.496224582195282], [0.5253114700317383, 0.45569396018981934, 0.6209162473678589]],
            [[0.8808955550193787, 0.4071536660194397, 0.4333076477050781], [0.8808956146240234, 0.6968275904655457, 0.4071536660194397], [0.8808955550193787, 0.4071537256240845, 0.7491355538368225]],
            [[0.9377320408821106, 0.5472549796104431, 0.3847135305404663], [0.9377320408821106, 0.9159339666366577, 0.3847135007381439], [0.9377320408821106, 0.3847135901451111, 0.5908510088920593]],
            [[0.9500001072883606, 0.8399999141693115, 0.42799997329711914], [0.7120000123977661, 0.949999988079071, 0.42799997329711914], [0.9500001072883606, 0.4920000433921814, 0.4280000329017639]],
            [[0.450999915599823, 0.8970000147819519, 0.612000048160553], [0.450999915599823, 0.8846666216850281, 0.8970000147819519], [0.5873332619667053, 0.8970000147819519, 0.45100003480911255]],
            [[0.49599987268447876, 0.7210000157356262, 0.8380001187324524], [0.4989999532699585, 0.4959999918937683, 0.8379999995231628], [0.49599987268447876, 0.8380000591278076, 0.7270000576972961]],
            [[0.4009999930858612, 0.40400004386901855, 0.5269999504089355], [0.4819999933242798, 0.4009999930858612, 0.5270000100135803], [0.40099990367889404, 0.4880000352859497, 0.5270000100135803]],
        ]
        let gradients = Array(ThemePreset.all[9..<18])
        XCTAssertEqual(ThemePreset.all.count, 45)
        XCTAssertEqual(Set(ThemePreset.all.map(\.id)).count, 45)
        for (i, preset) in gradients.enumerated() {
            XCTAssertEqual(preset.colors.count, 3)
            XCTAssertEqual(ThemePreset.page(of: preset.colors), 1)
            for (j, color) in preset.colors.enumerated() {
                XCTAssertEqual(color.red, expected[i][j][0], accuracy: 2e-6)
                XCTAssertEqual(color.green, expected[i][j][1], accuracy: 2e-6)
                XCTAssertEqual(color.blue, expected[i][j][2], accuracy: 2e-6)
            }
        }
    }

    func testDraggingAndResizingPreserveThePresetHarmony() throws {
        let preset = ThemePreset.all[16]
        let offsets = ThemeWheel.offsets(palette: preset.colors)
        XCTAssertEqual(ThemeWheel.harmony(palette: preset.colors), .analogous)
        let points = ThemeWheel.positions(dragged: CGPoint(x: 0.3, y: 0.4), index: 2, count: 3, offsets: offsets)
        XCTAssertEqual(points[2].x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(points[2].y, 0.4, accuracy: 1e-9)
        let two = ThemeWheel.offsets(count: 2, harmony: .analogous)
        XCTAssertEqual(two, [0, 1.0 / 9])
        XCTAssertEqual(ThemeWheel.offsets(count: 3, harmony: .complementary), [0, 5.0 / 12, -5.0 / 12])
        var space = Space(name: "Neutral preset", profileID: UUID())
        Spaces.setPalette(Array(repeating: ThemeColor(red: 0, green: 0, blue: 0), count: 3),
                          on: &space, harmony: .analogous)
        let restored = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(restored.themeHarmony, .analogous)
        Spaces.setThemeColors(["#808080"], on: &space)
        XCTAssertNil(space.themeHarmony)
    }

    func testMaximumIntensityIncreasesRenderedChromaSmoothly() {
        let source = ThemeColor(red: 0.401, green: 0.404, blue: 0.527)
        let originalChroma = (source.blue - source.red) * 0.62
        let newChroma = (source.ground(strength: 1, dark: true).blue - source.ground(strength: 1, dark: true).red)
            * Look.groundOpacity(dark: true, strength: 1)
        XCTAssertGreaterThan(newChroma, originalChroma * 1.3)
        XCTAssertEqual(Look.groundOpacity(dark: true, strength: 0.8), 0.62)
        XCTAssertEqual(Look.groundOpacity(dark: true, strength: 1), 0.9, accuracy: 1e-9)
        XCTAssertEqual(ThemeIntensity.boost(0.8), 0)
        XCTAssertEqual(ThemeIntensity.boost(1), 1, accuracy: 1e-9)
    }
}
