import Testing
import UniformTypeIdentifiers
import WatercolorCore
@testable import WatercolorStudio

@Suite struct PaintingDocumentTests {
    @Test func newDocumentContainsAValidDefaultProject() throws {
        let document = PaintingDocument()

        try document.project.validate()
        #expect(document.project.canvas == CanvasSize(width: 1600, height: 1200))
        #expect(document.project.paper == .coldPress)
        #expect(document.project.layers.count == 1)
        #expect(document.project.layers[0].name == "Layer 1")
        #expect(document.project.commands.isEmpty)
    }

    @Test func documentAdvertisesItsWatercolorJSONType() {
        #expect(UTType.watercolorPainting.identifier == "com.watercolorstudio.painting")
        #expect(PaintingDocument.filenameExtension == "watercolor")
        #expect(PaintingDocument.readableContentTypes == [.watercolorPainting])
    }

    @Test func newCanvasPresetsAndValidatedCustomSizesCreateEmptyProjects() throws {
        let landscape = NewCanvasConfiguration(preset: .landscape)
        let portrait = NewCanvasConfiguration(preset: .portrait)
        let square = NewCanvasConfiguration(preset: .square)
        let custom = NewCanvasConfiguration(width: 256, height: 4096, paper: .handmade)

        #expect(landscape.canvas == CanvasSize(width: 1600, height: 1200))
        #expect(portrait.canvas == CanvasSize(width: 1200, height: 1600))
        #expect(square.canvas == CanvasSize(width: 2048, height: 2048))
        let project = try custom.makeProject()
        #expect(project.canvas == CanvasSize(width: 256, height: 4096))
        #expect(project.paper == .handmade)
        #expect(project.layers.count == 1)
        #expect(project.commands.isEmpty)
        try project.validate()
    }

    @Test func newCanvasConfigurationRejectsEachDimensionOutsideSupportedBounds() {
        let cases = [
            NewCanvasConfiguration(width: 255, height: 256, paper: .coldPress),
            NewCanvasConfiguration(width: 256, height: 255, paper: .coldPress),
            NewCanvasConfiguration(width: 4097, height: 4096, paper: .coldPress),
            NewCanvasConfiguration(width: 4096, height: 4097, paper: .coldPress)
        ]

        for configuration in cases {
            #expect(throws: NewCanvasConfigurationError.self) {
                try configuration.makeProject()
            }
        }
    }

    @Test func onlyDocumentGroupNewDocumentsRequestInitialConfiguration() {
        let newDocument = PaintingDocument()
        let suppliedDocument = PaintingDocument(project: .newDefault())

        #expect(newDocument.needsInitialConfiguration)
        #expect(!suppliedDocument.needsInitialConfiguration)
    }
}
