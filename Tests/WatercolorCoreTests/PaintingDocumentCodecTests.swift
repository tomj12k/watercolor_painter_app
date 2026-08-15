import Foundation
import Testing
@testable import WatercolorCore

@Suite struct PaintingDocumentCodecTests {
    @Test func codecRoundTripsAProject() throws {
        var project = PaintingProject.newDefault()
        project.commands = [
            .stroke(StrokeCommand(
                id: UUID(uuidString: "23F51CB4-1309-4991-A799-7760BE57840B")!,
                layerID: project.layers[0].id,
                tool: .brush,
                brush: .default,
                points: [StrokePoint(x: 10, y: 20, pressure: 0.8, tiltX: 0.1, tiltY: -0.2, time: 1)]
            ))
        ]

        let data = try PaintingDocumentCodec.encode(project)

        #expect(try PaintingDocumentCodec.decode(data) == project)
    }

    @Test func codecRoundTripsEveryPaintingCommandCaseIncludingDuplicate() throws {
        let source = PaintLayer(
            id: UUID(uuidString: "A6A874FB-35CD-45D6-9897-5174EA57447D")!,
            name: "Source"
        )
        let duplicate = PaintLayer(
            id: UUID(uuidString: "5B80240C-91D5-4F72-A6F8-6AB4CA024BD4")!,
            name: "Duplicate"
        )
        let commands: [PaintingCommand] = [
            .stroke(StrokeCommand(
                id: UUID(uuidString: "2970DBFC-6EDE-49C7-97B6-6C7C031FD548")!,
                layerID: source.id,
                tool: .brush,
                brush: .default,
                points: [StrokePoint(x: 10, y: 20, pressure: 0.8, tiltX: 0.1, tiltY: -0.2, time: 1)]
            )),
            .clearLayer(LayerCommand(
                id: UUID(uuidString: "3C090F1C-BF64-4208-A59D-62B6684AF071")!,
                layerID: source.id
            )),
            .duplicateLayer(DuplicateLayerCommand(
                id: UUID(uuidString: "AB1D6BFD-89C2-43BB-A1B0-DF3E51231F41")!,
                sourceLayerID: source.id,
                destinationLayerID: duplicate.id
            )),
            .mergeDown(MergeDownCommand(
                id: UUID(uuidString: "93362DC6-B577-4449-B767-E5285B1D1377")!,
                sourceLayerID: duplicate.id,
                destinationLayerID: source.id
            )),
            .dryLayer(DryLayerCommand(
                id: UUID(uuidString: "2CA14A0F-531F-4BD7-88A4-A260CFE55F44")!,
                layerID: source.id,
                steps: 24
            ))
        ]
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [source],
            commands: commands
        )

        let decoded = try PaintingDocumentCodec.decode(PaintingDocumentCodec.encode(project))

        #expect(decoded.commands == commands)
        #expect(decoded == project)
    }

    @Test func codecWritesStableSortedKeyJSON() throws {
        let json = String(decoding: try PaintingDocumentCodec.encode(.newDefault()), as: UTF8.self)

        let canvas = try #require(json.range(of: "\"canvas\""))
        let commands = try #require(json.range(of: "\"commands\""))
        let layers = try #require(json.range(of: "\"layers\""))
        let paper = try #require(json.range(of: "\"paper\""))
        let schema = try #require(json.range(of: "\"schemaVersion\""))
        #expect(canvas.lowerBound < commands.lowerBound)
        #expect(commands.lowerBound < layers.lowerBound)
        #expect(layers.lowerBound < paper.lowerBound)
        #expect(paper.lowerBound < schema.lowerBound)
    }

    @Test func codecRejectsNewerSchema() throws {
        var project = PaintingProject.newDefault()
        project.schemaVersion = PaintingProject.currentSchemaVersion + 1
        let data = try JSONEncoder().encode(project)

        #expect(throws: DocumentCodecError.unsupportedSchema(project.schemaVersion)) {
            _ = try PaintingDocumentCodec.decode(data)
        }
    }

    @Test func codecRejectsEncodingANewerSchema() {
        var project = PaintingProject.newDefault()
        project.schemaVersion = PaintingProject.currentSchemaVersion + 1

        #expect(throws: DocumentCodecError.unsupportedSchema(project.schemaVersion)) {
            _ = try PaintingDocumentCodec.encode(project)
        }
    }

    @Test func codecDistinguishesMalformedData() {
        #expect(throws: DocumentCodecError.malformedData) {
            _ = try PaintingDocumentCodec.decode(Data("{not-json".utf8))
        }
    }

    @Test func codecValidatesDecodedProjects() throws {
        var project = PaintingProject.newDefault()
        project.canvas.width = PaintingProject.maximumCanvasDimension + 1
        let data = try JSONEncoder().encode(project)

        #expect(throws: DocumentCodecError.validationFailed(.invalidCanvasSize(project.canvas))) {
            _ = try PaintingDocumentCodec.decode(data)
        }
    }

    @Test func codecValidatesProjectsBeforeEncoding() {
        var project = PaintingProject.newDefault()
        project.layers = []

        #expect(throws: DocumentCodecError.validationFailed(.missingLayers)) {
            _ = try PaintingDocumentCodec.encode(project)
        }
    }
}
