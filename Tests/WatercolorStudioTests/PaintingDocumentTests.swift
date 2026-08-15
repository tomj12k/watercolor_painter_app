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
}
