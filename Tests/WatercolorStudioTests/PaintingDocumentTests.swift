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

    @Test func fileWrapperAdapterRoundTripsARepresentativeVersionThreePainting() throws {
        var project = PaintingProject.newDefault()
        var brush = BrushSettings.default
        brush.shape = .fan
        brush.texture = .granulating
        brush.spacing = 0.31
        project.commands = [
            .stroke(StrokeCommand(
                layerID: project.layers[0].id,
                tool: .brush,
                brush: brush,
                points: [StrokePoint(x: 40, y: 50, pressure: 0.8, tiltX: 0, tiltY: 0, time: 0)]
            ))
        ]
        let wrapper = FileWrapper(
            regularFileWithContents: try PaintingDocumentCodec.encode(project)
        )

        let document = try PaintingDocument(fileWrapper: wrapper)

        #expect(document.project == project)
        #expect(!document.needsInitialConfiguration)
    }

    @Test func fileWrapperAdapterPreservesMalformedInvalidAndNewerCategories() throws {
        let malformed = FileWrapper(regularFileWithContents: Data("not json".utf8))
        #expect(throws: DocumentCodecError.malformedData) {
            _ = try PaintingDocument(fileWrapper: malformed)
        }

        let invalidID = UUID(uuidString: "587A9004-E1B2-4495-9D1B-7DA676985804")!
        var invalidProject = PaintingProject.newDefault()
        var invalidBrush = BrushSettings.default
        invalidBrush.spacing = 0.01
        invalidProject.commands = [
            .stroke(StrokeCommand(
                id: invalidID,
                layerID: invalidProject.layers[0].id,
                tool: .brush,
                brush: invalidBrush,
                points: [StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
            ))
        ]
        let invalid = FileWrapper(regularFileWithContents: try JSONEncoder().encode(invalidProject))
        #expect(throws: DocumentCodecError.validationFailed(.invalidBrushParameter(invalidID))) {
            _ = try PaintingDocument(fileWrapper: invalid)
        }

        var newerProject = PaintingProject.newDefault()
        newerProject.schemaVersion = PaintingProject.currentSchemaVersion + 1
        let newer = FileWrapper(regularFileWithContents: try JSONEncoder().encode(newerProject))
        #expect(throws: DocumentCodecError.unsupportedSchema(newerProject.schemaVersion)) {
            _ = try PaintingDocument(fileWrapper: newer)
        }
    }

    @Test func fileWrapperAdapterPreservesOverBudgetCategoryFromCodecBoundary() {
        let wrapper = FileWrapper(regularFileWithContents: Data("{}".utf8))
        let expected = DocumentCodecError.validationFailed(.documentByteLimitExceeded(300_000_000))

        #expect(throws: expected) {
            _ = try PaintingDocument(fileWrapper: wrapper, decode: { _ in throw expected })
        }
    }

    @Test func directoryWrapperIsMalformedInsteadOfSilentlyCreatingADocument() {
        let directory = FileWrapper(directoryWithFileWrappers: [:])

        #expect(throws: DocumentCodecError.malformedData) {
            _ = try PaintingDocument(fileWrapper: directory)
        }
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

    @Test func newCanvasActionValidityMatchesTheExactSupportedDimensionBounds() {
        let valid = [
            NewCanvasConfiguration(width: 256, height: 256, paper: .coldPress),
            NewCanvasConfiguration(width: 4096, height: 4096, paper: .rough)
        ]
        let invalid = [
            NewCanvasConfiguration(width: 255, height: 256, paper: .coldPress),
            NewCanvasConfiguration(width: 256, height: 255, paper: .coldPress),
            NewCanvasConfiguration(width: 4097, height: 4096, paper: .rough),
            NewCanvasConfiguration(width: 4096, height: 4097, paper: .rough)
        ]

        #expect(valid.allSatisfy { $0.isValid })
        #expect(invalid.allSatisfy { !$0.isValid })
    }

    @Test func onlyDocumentGroupNewDocumentsRequestInitialConfiguration() {
        let newDocument = PaintingDocument()
        let suppliedDocument = PaintingDocument(project: .newDefault())

        #expect(newDocument.needsInitialConfiguration)
        #expect(!suppliedDocument.needsInitialConfiguration)
    }
}
