import Testing
@testable import WatercolorCore

@Suite struct PresetTests {
    @Test func wetOnWetAddsMoreWaterThanDryBrush() {
        let base = BrushSettings.default
        #expect(base.applying(.wetOnWet).water > base.applying(.dryBrush).water)
    }

    @Test func applyingPresetPreservesBrushIdentityAndUsesPresetStyle() {
        var base = BrushSettings.default
        base.shape = .flat
        base.hair = .bristle
        base.texture = .mottled
        base.color = PaintColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7)
        base.size = 48

        let result = base.applying(.bloom)

        #expect(result.shape == base.shape)
        #expect(result.hair == base.hair)
        #expect(result.texture == base.texture)
        #expect(result.color == base.color)
        #expect(result.size == base.size)
        #expect(result.style == .bloom)
    }
}
