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

        #expect(project.schemaVersion == 1)
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
}
