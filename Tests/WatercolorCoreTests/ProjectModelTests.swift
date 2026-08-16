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
