import Foundation
import Testing
@testable import WatercolorCore

@Suite struct ProjectModelTests {
    @Test func defaultProjectIsValidAndRoundTrips() throws {
        let project = PaintingProject.newDefault()
        try project.validate()
        let data = try JSONEncoder().encode(project)
        #expect(try JSONDecoder().decode(PaintingProject.self, from: data) == project)
    }

    @Test func oversizedCanvasIsRejected() {
        var project = PaintingProject.newDefault()
        project.canvas = CanvasSize(width: 4097, height: 1200)
        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func defaultProjectUsesTheStudioDefaults() {
        let project = PaintingProject.newDefault()

        #expect(project.schemaVersion == PaintingProject.currentSchemaVersion)
        #expect(project.canvas == CanvasSize(width: 1600, height: 1200))
        #expect(project.paper == .coldPress)
        #expect(project.layers.count == 1)
        #expect(project.layers[0].isVisible)
        #expect(BrushSettings.default.style == .transparentWash)
        #expect(BrushSettings.default.shape == .round)
        #expect(BrushSettings.default.hair == .sable)
        #expect(BrushSettings.default.behaviorVersion == 2)
        #expect(BrushSettings.default.spacing == 0.18)
        #expect(BrushSettings.default.rotation == 0)
        #expect(BrushSettings.default.bristleStrength == 0.5)
        #expect(BrushSettings.default.textureStrength == 0.5)
        #expect(BrushSettings.legacyDynamics.behaviorVersion == 0)
        #expect(BrushSettings.legacyDynamics.spacing == 0.18)
        #expect(BrushSettings.legacyDynamics.rotation == 0)
        #expect(BrushSettings.legacyDynamics.bristleStrength == 0.5)
        #expect(BrushSettings.legacyDynamics.textureStrength == 0.5)
    }

    @Test func brushSettingsCodableRoundTripIncludesEveryDynamicField() throws {
        var brush = BrushSettings.default
        brush.behaviorVersion = 0
        brush.spacing = 0.42
        brush.rotation = -123.5
        brush.bristleStrength = 0.25
        brush.textureStrength = 0.75

        let data = try JSONEncoder().encode(brush)
        let encoded = try JSONDecoder().decode(EncodedBrushDynamics.self, from: data)

        #expect(encoded.behaviorVersion == 0)
        #expect(encoded.spacing == 0.42)
        #expect(encoded.rotation == -123.5)
        #expect(encoded.bristleStrength == 0.25)
        #expect(encoded.textureStrength == 0.75)
        #expect(try JSONDecoder().decode(BrushSettings.self, from: data) == brush)
    }

    @Test func brushSettingsDecodesMissingDynamicsAsLegacyDefaults() throws {
        let versionTwoBrush = Data(#"""
        {
          "shape": "flat",
          "hair": "bristle",
          "texture": "mottled",
          "style": "glazing",
          "color": { "red": 0.2, "green": 0.4, "blue": 0.6, "alpha": 0.8 },
          "size": 48,
          "opacity": 0.25,
          "flow": 0.3,
          "water": 0.35,
          "granulation": 0.4,
          "edgeBloom": 0.45
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(BrushSettings.self, from: versionTwoBrush)

        #expect(decoded.shape == .flat)
        #expect(decoded.hair == .bristle)
        #expect(decoded.texture == .mottled)
        #expect(decoded.style == .glazing)
        #expect(decoded.color == PaintColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8))
        #expect(decoded.size == 48)
        #expect(decoded.behaviorVersion == BrushSettings.legacyDynamics.behaviorVersion)
        #expect(decoded.spacing == BrushSettings.legacyDynamics.spacing)
        #expect(decoded.rotation == BrushSettings.legacyDynamics.rotation)
        #expect(decoded.bristleStrength == BrushSettings.legacyDynamics.bristleStrength)
        #expect(decoded.textureStrength == BrushSettings.legacyDynamics.textureStrength)
    }

    @Test func brushDynamicsAcceptTheirExactValidationBounds() throws {
        var lowerBounds = BrushSettings.default
        lowerBounds.behaviorVersion = 0
        lowerBounds.spacing = 0.08
        lowerBounds.rotation = -180
        lowerBounds.bristleStrength = 0
        lowerBounds.textureStrength = 0
        try projectFixture(brush: lowerBounds).validate()

        var upperBounds = BrushSettings.default
        upperBounds.behaviorVersion = 2
        upperBounds.spacing = 0.60
        upperBounds.rotation = 180
        upperBounds.bristleStrength = 1
        upperBounds.textureStrength = 1
        try projectFixture(brush: upperBounds).validate()
    }

    @Test func invalidBrushDynamicsFailValidation() {
        let invalidBrushes: [BrushSettings] = [
            configuredBrush { $0.behaviorVersion = -1 },
            configuredBrush { $0.behaviorVersion = 3 },
            configuredBrush { $0.spacing = .nan },
            configuredBrush { $0.spacing = .infinity },
            configuredBrush { $0.spacing = 0.08.nextDown },
            configuredBrush { $0.spacing = 0.60.nextUp },
            configuredBrush { $0.rotation = .nan },
            configuredBrush { $0.rotation = -.infinity },
            configuredBrush { $0.rotation = (-180.0).nextDown },
            configuredBrush { $0.rotation = 180.0.nextUp },
            configuredBrush { $0.bristleStrength = .nan },
            configuredBrush { $0.bristleStrength = .infinity },
            configuredBrush { $0.bristleStrength = 0.0.nextDown },
            configuredBrush { $0.bristleStrength = 1.0.nextUp },
            configuredBrush { $0.textureStrength = .nan },
            configuredBrush { $0.textureStrength = -.infinity },
            configuredBrush { $0.textureStrength = 0.0.nextDown },
            configuredBrush { $0.textureStrength = 1.0.nextUp }
        ]

        for brush in invalidBrushes {
            let project = projectFixture(brush: brush)
            #expect(throws: ProjectValidationError.invalidBrushParameter(testStrokeID)) {
                try project.validate()
            }
        }
    }

    @Test func canvasSmallerThanTheSupportedMinimumIsRejected() {
        var project = PaintingProject.newDefault()
        project.canvas = CanvasSize(width: 255, height: 1200)

        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func projectsWithMoreThanTwelveLayersAreRejected() {
        var project = PaintingProject.newDefault()
        project.layers = (0...12).map { index in
            PaintLayer(name: "Layer \(index)")
        }

        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func projectsWithDuplicateLayerIdentifiersAreRejected() {
        var project = PaintingProject.newDefault()
        project.layers.append(
            PaintLayer(id: project.layers[0].id, name: "Duplicate")
        )

        #expect(throws: ProjectValidationError.self) { try project.validate() }
    }

    @Test func sRGBAndLinearConversionsMatchTheStandardTransferFunction() {
        let linear = PaintColor.fromSRGB(red: 0.5, green: 0.04045, blue: 1, alpha: 0.75)

        #expect(abs(linear.red - 0.214_041_140_482_232_55) < 0.000_000_001)
        #expect(abs(linear.green - 0.003_130_804_953_560_371_3) < 0.000_000_001)
        #expect(linear.blue == 1)
        #expect(linear.alpha == 0.75)

        let roundTrip = linear.convertedToSRGB()
        #expect(abs(roundTrip.red - 0.5) < 0.000_000_001)
        #expect(abs(roundTrip.green - 0.04045) < 0.000_000_1)
        #expect(abs(roundTrip.blue - 1) < 0.000_000_001)
        #expect(roundTrip.alpha == 0.75)
    }

    @Test func representativePigmentsMixInLinearLight() {
        let dark = PaintColor.fromSRGB(red: 0, green: 0, blue: 0)
        let light = PaintColor.fromSRGB(red: 1, green: 1, blue: 1)

        let mixed = dark.mixedLinearly(with: light, ratio: 0.5).convertedToSRGB()

        #expect(abs(mixed.red - 0.735_356_983_052_449_5) < 0.000_000_001)
        #expect(abs(mixed.green - mixed.red) < 0.000_000_001)
        #expect(abs(mixed.blue - mixed.red) < 0.000_000_001)
    }

    @Test func conservativeStorageChargeBoundsHighPrecisionJSON() throws {
        var project = PaintingProject.newDefault()
        var brush = BrushSettings.default
        brush.color = PaintColor(
            red: 0.123_456_789_012_345_67,
            green: 0.987_654_321_098_765_4,
            blue: 0.555_555_555_555_555_6,
            alpha: 0.999_999_999_999_999_9
        )
        let point = StrokePoint(
            x: 1_234.567_890_123_456_7,
            y: 1_111.222_333_444_555_6,
            pressure: 0.123_456_789_012_345_67,
            tiltX: -0.987_654_321_098_765_4,
            tiltY: 0.555_555_555_555_555_6,
            time: Double.greatestFiniteMagnitude
        )
        project.commands = [
            .stroke(StrokeCommand(
                layerID: project.layers[0].id,
                tool: .brush,
                brush: brush,
                points: Array(repeating: point, count: 128)
            ))
        ]

        let encoded = try JSONEncoder().encode(project)
        let storageCharge = try project.serializedStorageCharge()

        #expect(storageCharge >= encoded.count)
        try project.validate(limits: ProjectAdmissionLimits(
            maximumCommandCount: 1,
            maximumTotalStrokePointCount: 128,
            maximumSerializedStorageBytes: storageCharge
        ))
    }

    @Test func distributedCommandOverheadIsRejectedByStorageAdmission() {
        var project = PaintingProject.newDefault()
        project.commands = (0..<12).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let limits = ProjectAdmissionLimits(
            maximumCommandCount: 12,
            maximumTotalStrokePointCount: 128,
            maximumSerializedStorageBytes: 24 * 1024
        )

        do {
            try project.validate(limits: limits)
            Issue.record("Expected distributed command storage to be rejected")
        } catch let ProjectValidationError.documentByteLimitExceeded(required) {
            #expect(required > limits.maximumSerializedStorageBytes)
        } catch {
            Issue.record("Expected documentByteLimitExceeded, got \(error)")
        }
    }
}

private let testStrokeID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

private struct EncodedBrushDynamics: Decodable {
    let behaviorVersion: Int
    let spacing: Double
    let rotation: Double
    let bristleStrength: Double
    let textureStrength: Double
}

private func configuredBrush(_ configure: (inout BrushSettings) -> Void) -> BrushSettings {
    var brush = BrushSettings.default
    configure(&brush)
    return brush
}

private func projectFixture(brush: BrushSettings) -> PaintingProject {
    var project = PaintingProject.newDefault()
    project.commands = [.stroke(StrokeCommand(
        id: testStrokeID,
        layerID: project.layers[0].id,
        tool: .brush,
        brush: brush,
        points: [StrokePoint(x: 10, y: 20, pressure: 0.8, tiltX: 0, tiltY: 0, time: 1)]
    ))]
    return project
}
