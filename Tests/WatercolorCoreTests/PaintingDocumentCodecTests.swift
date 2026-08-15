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
