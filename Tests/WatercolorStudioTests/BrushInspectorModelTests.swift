import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite @MainActor struct BrushInspectorModelTests {
    @Test func dynamicsSettersClampToPersistedValidationBounds() throws {
        let model = try makeModel()

        model.setBrushSpacing(-4)
        model.setBrushRotation(900)
        model.setBristleStrength(-1)
        model.setTextureStrength(12)

        #expect(model.brush.spacing == 0.08)
        #expect(model.brush.rotation == 180)
        #expect(model.brush.bristleStrength == 0)
        #expect(model.brush.textureStrength == 1)

        model.setBrushSpacing(4)
        model.setBrushRotation(-900)
        model.setBristleStrength(8)
        model.setTextureStrength(-3)

        #expect(model.brush.spacing == 0.60)
        #expect(model.brush.rotation == -180)
        #expect(model.brush.bristleStrength == 1)
        #expect(model.brush.textureStrength == 0)
    }

    @Test func dynamicsSettersIgnoreEveryNonfiniteInput() throws {
        let model = try makeModel()
        model.brush.spacing = 0.27
        model.brush.rotation = 42
        model.brush.bristleStrength = 0.31
        model.brush.textureStrength = 0.74

        model.setBrushSpacing(.nan)
        model.setBrushRotation(.infinity)
        model.setBristleStrength(-.infinity)
        model.setTextureStrength(.nan)

        #expect(model.brush.spacing == 0.27)
        #expect(model.brush.rotation == 42)
        #expect(model.brush.bristleStrength == 0.31)
        #expect(model.brush.textureStrength == 0.74)
    }

    @Test func changingDynamicsPreservesIdentityColorAndPaintParameters() throws {
        let model = try makeModel()
        model.brush = distinctiveBrush()
        let original = model.brush

        model.setBrushSpacing(0.44)
        model.setBrushRotation(-73)
        model.setBristleStrength(0.82)
        model.setTextureStrength(0.16)

        #expect(model.brush.behaviorVersion == original.behaviorVersion)
        #expect(model.brush.shape == original.shape)
        #expect(model.brush.hair == original.hair)
        #expect(model.brush.texture == original.texture)
        #expect(model.brush.style == original.style)
        #expect(model.brush.color == original.color)
        #expect(model.brush.size == original.size)
        #expect(model.brush.opacity == original.opacity)
        #expect(model.brush.flow == original.flow)
        #expect(model.brush.water == original.water)
        #expect(model.brush.granulation == original.granulation)
        #expect(model.brush.edgeBloom == original.edgeBloom)
    }

    @Test func resetDynamicsRestoresVersionOneDefaultsAndPreservesEveryOtherField() throws {
        let model = try makeModel()
        model.brush = distinctiveBrush()
        let original = model.brush

        model.resetBrushDynamics()

        #expect(model.brush.spacing == 0.18)
        #expect(model.brush.rotation == 0)
        #expect(model.brush.bristleStrength == 0.50)
        #expect(model.brush.textureStrength == 0.50)
        #expect(model.brush.behaviorVersion == original.behaviorVersion)
        #expect(model.brush.shape == original.shape)
        #expect(model.brush.hair == original.hair)
        #expect(model.brush.texture == original.texture)
        #expect(model.brush.style == original.style)
        #expect(model.brush.color == original.color)
        #expect(model.brush.size == original.size)
        #expect(model.brush.opacity == original.opacity)
        #expect(model.brush.flow == original.flow)
        #expect(model.brush.water == original.water)
        #expect(model.brush.granulation == original.granulation)
        #expect(model.brush.edgeBloom == original.edgeBloom)
    }

    @Test func everyBrushIdentityHasUniqueUsefulArtistLanguage() {
        assertUsefulUniqueDescriptions(
            WatercolorStyle.allCases.map(BrushInspectorPresentation.description(for:)),
            rawValues: WatercolorStyle.allCases.map(\.rawValue)
        )
        assertUsefulUniqueDescriptions(
            BrushShape.allCases.map(BrushInspectorPresentation.description(for:)),
            rawValues: BrushShape.allCases.map(\.rawValue)
        )
        assertUsefulUniqueDescriptions(
            BrushHair.allCases.map(BrushInspectorPresentation.description(for:)),
            rawValues: BrushHair.allCases.map(\.rawValue)
        )
        assertUsefulUniqueDescriptions(
            BrushTexture.allCases.map(BrushInspectorPresentation.description(for:)),
            rawValues: BrushTexture.allCases.map(\.rawValue)
        )
    }

    @Test func brushRecipeChangesForEachIdentityChoice() {
        let original = distinctiveBrush()
        let baseRecipe = BrushInspectorPresentation.recipe(for: original)
        var variants: [BrushSettings] = []

        var style = original
        style.style = .wetOnWet
        variants.append(style)
        var shape = original
        shape.shape = .fan
        variants.append(shape)
        var hair = original
        hair.hair = .mop
        variants.append(hair)
        var texture = original
        texture.texture = .salt
        variants.append(texture)

        #expect(!baseRecipe.isEmpty)
        #expect(variants.allSatisfy {
            BrushInspectorPresentation.recipe(for: $0) != baseRecipe
        })
    }

    @Test func inspectorPresentationDefinesExactSectionsControlsAndAccessibility() {
        #expect(BrushInspectorPresentation.sectionTitles == [
            "Identity", "Color", "Paint", "Dynamics"
        ])
        #expect(BrushInspectorPresentation.dynamics.map(\.title) == [
            "Spacing", "Rotation", "Bristle", "Texture strength"
        ])
        #expect(BrushInspectorPresentation.dynamics.map(\.range) == [
            0.08...0.60, -180...180, 0...1, 0...1
        ])
        #expect(BrushInspectorPresentation.dynamics.map(\.step) == [0.01, 1, 0.01, 0.01])

        let allAccessibility = BrushInspectorPresentation.identityAccessibility
            + BrushInspectorPresentation.colorAccessibility
            + BrushInspectorPresentation.paintAccessibility
            + BrushInspectorPresentation.dynamics.map(\.accessibility)
            + [
                BrushInspectorPresentation.recipeAccessibility,
                BrushInspectorPresentation.resetDynamicsAccessibility
            ]
        #expect(allAccessibility.allSatisfy {
            !$0.label.isEmpty && !$0.help.isEmpty
        })
        #expect(Set(allAccessibility.map(\.label)).count == allAccessibility.count)
    }

    @Test func resetLabelMeetsNormalTextContrastAgainstInspectorBackground() {
        let contrast = StudioPalette.contrastRatio(
            foreground: BrushInspectorPresentation.resetDynamicsLabelColor,
            background: StudioPalette.carbonSRGB
        )

        #expect(contrast >= 4.5)
    }

    @Test func paletteContrastUsesWCAGRelativeLuminance() {
        let black = StudioPaletteSRGB(red: 0, green: 0, blue: 0)
        let white = StudioPaletteSRGB(red: 1, green: 1, blue: 1)

        #expect(abs(StudioPalette.contrastRatio(foreground: black, background: white) - 21) < 1e-12)
        #expect(
            StudioPalette.contrastRatio(foreground: black, background: white)
                == StudioPalette.contrastRatio(foreground: white, background: black)
        )
    }

    private func makeModel() throws -> StudioModel {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        return StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
    }

    private func distinctiveBrush() -> BrushSettings {
        BrushSettings(
            shape: .filbert,
            hair: .synthetic,
            texture: .mottled,
            style: .glazing,
            color: PaintColor(red: 0.21, green: 0.34, blue: 0.55, alpha: 0.88),
            size: 67,
            opacity: 0.43,
            flow: 0.71,
            water: 0.22,
            granulation: 0.63,
            edgeBloom: 0.39,
            behaviorVersion: 1,
            spacing: 0.33,
            rotation: 27,
            bristleStrength: 0.64,
            textureStrength: 0.79
        )
    }

    private func assertUsefulUniqueDescriptions(_ descriptions: [String], rawValues: [String]) {
        #expect(descriptions.allSatisfy { $0.count >= 20 })
        #expect(Set(descriptions).count == descriptions.count)
        #expect(zip(descriptions, rawValues).allSatisfy { description, rawValue in
            description.lowercased() != rawValue.lowercased()
        })
        let internalTerms = ["shader", "pipeline", "stamp", "parameter", "seed"]
        #expect(descriptions.allSatisfy { description in
            internalTerms.allSatisfy { !description.lowercased().contains($0) }
        })
    }
}
