import Testing
@testable import WatercolorCore

@Suite struct PresetTests {
    @Test func wetOnWetAddsMoreWaterThanDryBrush() {
        let base = BrushSettings.default
        #expect(base.applying(.wetOnWet).water > base.applying(.dryBrush).water)
    }

    @Test func everyPresetPreservesBrushIdentityAndDynamicsAndUsesPresetStyle() {
        var base = BrushSettings.default
        base.shape = .flat
        base.hair = .bristle
        base.texture = .mottled
        base.color = PaintColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7)
        base.size = 48
        base.behaviorVersion = 0
        base.spacing = 0.42
        base.rotation = -75
        base.bristleStrength = 0.25
        base.textureStrength = 0.85

        for preset in WatercolorStyle.allCases {
            let result = base.applying(preset)

            #expect(result.shape == base.shape)
            #expect(result.hair == base.hair)
            #expect(result.texture == base.texture)
            #expect(result.color == base.color)
            #expect(result.size == base.size)
            #expect(result.behaviorVersion == base.behaviorVersion)
            #expect(result.spacing == base.spacing)
            #expect(result.rotation == base.rotation)
            #expect(result.bristleStrength == base.bristleStrength)
            #expect(result.textureStrength == base.textureStrength)
            #expect(result.style == preset)
        }
    }
}
