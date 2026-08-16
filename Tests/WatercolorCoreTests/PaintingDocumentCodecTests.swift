import Foundation
import Testing
@testable import WatercolorCore

@Suite(.serialized) struct PaintingDocumentCodecTests {
    @Test func codecRejectsEncodedDocumentsAboveTheByteLimit() {
        let project = PaintingProject.pointLimitFixture(
            pointCount: 128,
            point: StrokePoint(
                x: 123.456_789_012_345_67,
                y: 234.567_890_123_456_78,
                pressure: 0.123_456_789_012_345_67,
                tiltX: -0.123_456_789_012_345_67,
                tiltY: 0.123_456_789_012_345_67,
                time: 123_456_789_012_345.67
            )
        )
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 4 * 1024,
            maximumTotalStrokePointCount: 128
        )

        do {
            _ = try PaintingDocumentCodec.encode(project, limits: limits)
            Issue.record("Expected encoding above the byte limit to fail")
        } catch let DocumentCodecError.validationFailed(.documentByteLimitExceeded(byteCount)) {
            #expect(byteCount > limits.maximumDocumentBytes)
        } catch {
            Issue.record("Expected documentByteLimitExceeded, got \(error)")
        }
    }

    @Test func codecRoundTripsAProjectAtTheAggregatePointLimit() throws {
        let project = PaintingProject.pointLimitFixture(
            pointCount: 128,
            point: StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 64 * 1024,
            maximumTotalStrokePointCount: 128
        )

        let data = try PaintingDocumentCodec.encode(project, limits: limits)

        #expect(data.count <= limits.maximumDocumentBytes)
        #expect(try PaintingDocumentCodec.decode(data, limits: limits) == project)
    }

    @Test func benchmarkConfiguredMaximumLengthEncodingLatency() throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_BENCHMARK"] == "1" else {
            return
        }
        let configuredMaximumPointCount = 512
        let project = PaintingProject.pointLimitFixture(
            pointCount: configuredMaximumPointCount,
            point: StrokePoint(
                x: 123.456_789_012_345_67,
                y: 234.567_890_123_456_78,
                pressure: 0.876_543_210_987_654_3,
                tiltX: -0.123_456_789_012_345_67,
                tiltY: 0.123_456_789_012_345_67,
                time: 123_456_789_012_345.67
            )
        )
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 256 * 1024,
            maximumTotalStrokePointCount: configuredMaximumPointCount
        )

        let start = ProcessInfo.processInfo.systemUptime
        let data = try PaintingDocumentCodec.encode(project, limits: limits)
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000

        print(
            "WATERCOLOR_RESOURCE_LATENCY phase=document_encode "
                + "configured_max_points=\(configuredMaximumPointCount) "
                + "elapsed_ms=\(String(format: "%.3f", elapsedMilliseconds)) "
                + "encoded_bytes=\(data.count)"
        )
        #expect(data.count <= limits.maximumDocumentBytes)
        #expect(elapsedMilliseconds < 1_000)
    }

    @Test func codecRejectsDataAboveTheDocumentByteLimitBeforeDecoding() {
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 4 * 1024,
            maximumTotalStrokePointCount: 128
        )
        let data = Data(repeating: 0, count: limits.maximumDocumentBytes + 1)

        #expect(throws: DocumentCodecError.validationFailed(.documentByteLimitExceeded(data.count))) {
            _ = try PaintingDocumentCodec.decode(data, limits: limits)
        }
    }

    @Test func codecRejectsProjectsWhoseAggregateStrokePointsExceedTheLimit() {
        let project = PaintingProject.pointLimitFixture(
            pointCount: 129,
            point: StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 64 * 1024,
            maximumTotalStrokePointCount: 128
        )

        #expect(throws: DocumentCodecError.validationFailed(.totalStrokePointLimitExceeded(129))) {
            _ = try PaintingDocumentCodec.encode(project, limits: limits)
        }
    }

    @Test func codecUsesConservativeStorageAdmissionBeforeEncoding() throws {
        var project = PaintingProject.newDefault()
        project.commands = (0..<12).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let limits = PaintingDocumentCodec.AdmissionLimits(
            maximumDocumentBytes: 24 * 1024,
            maximumTotalStrokePointCount: 128
        )
        #expect(try JSONEncoder().encode(project).count < limits.maximumDocumentBytes)

        do {
            _ = try PaintingDocumentCodec.encode(project, limits: limits)
            Issue.record("Expected conservative storage admission to reject the project")
        } catch let DocumentCodecError.validationFailed(.documentByteLimitExceeded(required)) {
            #expect(required > limits.maximumDocumentBytes)
        } catch {
            Issue.record("Expected documentByteLimitExceeded, got \(error)")
        }
    }

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

    @Test func codecMigratesVersionOneSRGBMidtonesAndLegacyDynamicsExactlyOnce() throws {
        let layer = PaintLayer(
            id: UUID(uuidString: "751CB1CA-E34A-4633-8CC9-0C999F0BE4C8")!,
            name: "Legacy layer"
        )
        var brush = BrushSettings.default
        brush.color = PaintColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        let legacy = PaintingProject(
            schemaVersion: 1,
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(.fixture(layerID: layer.id, brush: brush))]
        )

        let migrated = try PaintingDocumentCodec.decode(JSONEncoder().encode(legacy))
        let migratedStroke = try #require(migrated.commands.first?.stroke)
        #expect(migrated.schemaVersion == 3)
        #expect(abs(migratedStroke.brush.color.red - 0.214_041_140_482_232_55) < 1e-12)
        #expect(abs(migratedStroke.brush.color.green - 0.050_876_088_171_556_79) < 1e-12)
        #expect(abs(migratedStroke.brush.color.blue - 0.522_521_553_968_392_1) < 1e-12)
        #expect(migratedStroke.brush.behaviorVersion == 0)
        #expect(migratedStroke.brush.spacing == 0.18)
        #expect(migratedStroke.brush.rotation == 0)
        #expect(migratedStroke.brush.bristleStrength == 0.5)
        #expect(migratedStroke.brush.textureStrength == 0.5)

        let reencoded = try PaintingDocumentCodec.encode(migrated)
        let redecoded = try PaintingDocumentCodec.decode(reencoded)
        #expect(redecoded == migrated)
        let redecodedStroke = try #require(redecoded.commands.first?.stroke)
        #expect(redecodedStroke.brush.color == migratedStroke.brush.color)
        #expect(try JSONDecoder().decode(SchemaVersionFixture.self, from: reencoded).schemaVersion == 3)
    }

    @Test func codecMigratesVersionTwoBrushesWithoutVisualFieldLossOrColorRemigration() throws {
        let layer = PaintLayer(name: "Linear layer")
        var brush = BrushSettings.default
        brush.shape = .fan
        brush.hair = .synthetic
        brush.texture = .salt
        brush.style = .bloom
        brush.color = PaintColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        brush.size = 73
        brush.opacity = 0.44
        brush.flow = 0.55
        brush.water = 0.66
        brush.granulation = 0.77
        brush.edgeBloom = 0.88
        brush.behaviorVersion = 1
        brush.spacing = 0.31
        brush.rotation = 45
        brush.bristleStrength = 0.2
        brush.textureStrength = 0.9
        let current = PaintingProject(
            schemaVersion: 2,
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(.fixture(layerID: layer.id, brush: brush))]
        )

        let decoded = try PaintingDocumentCodec.decode(JSONEncoder().encode(current))
        let decodedStroke = try #require(decoded.commands.first?.stroke)

        #expect(decoded.schemaVersion == 3)
        #expect(decodedStroke.brush.shape == brush.shape)
        #expect(decodedStroke.brush.hair == brush.hair)
        #expect(decodedStroke.brush.texture == brush.texture)
        #expect(decodedStroke.brush.style == brush.style)
        #expect(decodedStroke.brush.color == brush.color)
        #expect(decodedStroke.brush.size == brush.size)
        #expect(decodedStroke.brush.opacity == brush.opacity)
        #expect(decodedStroke.brush.flow == brush.flow)
        #expect(decodedStroke.brush.water == brush.water)
        #expect(decodedStroke.brush.granulation == brush.granulation)
        #expect(decodedStroke.brush.edgeBloom == brush.edgeBloom)
        #expect(decodedStroke.brush.behaviorVersion == 0)
        #expect(decodedStroke.brush.spacing == 0.18)
        #expect(decodedStroke.brush.rotation == 0)
        #expect(decodedStroke.brush.bristleStrength == 0.5)
        #expect(decodedStroke.brush.textureStrength == 0.5)
    }

    @Test func codecPreservesVersionThreeDynamicsThroughEncodeDecode() throws {
        var project = PaintingProject.newDefault()
        var brush = BrushSettings.default
        brush.spacing = 0.37
        brush.rotation = 123
        brush.bristleStrength = 0.24
        brush.textureStrength = 0.86
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id, brush: brush))]

        let encoded = try PaintingDocumentCodec.encode(project)
        let decoded = try PaintingDocumentCodec.decode(encoded)

        #expect(decoded == project)
        #expect(try #require(decoded.commands.first?.stroke).brush == brush)
    }

    @Test func codecDefaultsMissingVersionThreeDynamicsToLegacyBehavior() throws {
        var project = PaintingProject.newDefault()
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id))]
        let data = try replacingBrushDynamics(
            in: JSONEncoder().encode(project),
            with: [:],
            removingExistingDynamics: true
        )

        let decoded = try PaintingDocumentCodec.decode(data)
        let brush = try #require(decoded.commands.first?.stroke).brush

        #expect(decoded.schemaVersion == 3)
        #expect(brush.behaviorVersion == 0)
        #expect(brush.spacing == 0.18)
        #expect(brush.rotation == 0)
        #expect(brush.bristleStrength == 0.5)
        #expect(brush.textureStrength == 0.5)
    }

    @Test func codecRejectsMalformedAndUnknownBehaviorVersions() throws {
        var project = PaintingProject.newDefault()
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id))]
        let encoded = try JSONEncoder().encode(project)
        let malformed = try replacingBrushDynamics(in: encoded, with: ["behaviorVersion": "new"])
        let unknown = try replacingBrushDynamics(in: encoded, with: ["behaviorVersion": 42])

        #expect(throws: DocumentCodecError.malformedData) {
            _ = try PaintingDocumentCodec.decode(malformed)
        }
        #expect(throws: DocumentCodecError.validationFailed(.invalidBrushParameter(project.commands[0].id))) {
            _ = try PaintingDocumentCodec.decode(unknown)
        }
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

    @Test func codecRejectsUnsafeNestedBrushAndLayerNumbers() throws {
        var project = PaintingProject.newDefault()
        project.layers[0].opacity = 1.01
        #expect(throws: DocumentCodecError.validationFailed(.invalidLayerOpacity(project.layers[0].id, 1.01))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        project = .newDefault()
        var brush = BrushSettings.default
        brush.size = 301
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id, brush: brush))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidBrushSize(project.commands[0].id, 301))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        project = .newDefault()
        brush = .default
        brush.color.red = -0.01
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id, brush: brush))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidColorComponent(project.commands[0].id))) {
            _ = try PaintingDocumentCodec.encode(project)
        }
    }

    @Test func codecRejectsUnsafeStrokePointsBeforeRendererConversion() throws {
        let layer = PaintLayer(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Layer 1"
        )
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(.fixture(
                layerID: layer.id,
                points: [StrokePoint(x: 1e300, y: 20, pressure: 0.8, tiltX: 0, tiltY: 0, time: 1)]
            ))]
        )
        let unsafeJSON = try JSONEncoder().encode(project)

        #expect(throws: DocumentCodecError.validationFailed(.invalidStrokePoint(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            0
        ))) {
            _ = try PaintingDocumentCodec.decode(unsafeJSON)
        }
    }

    @Test func codecRejectsEmptyOversizedAndNonMonotonicStrokes() throws {
        var project = PaintingProject.newDefault()
        project.commands = [.stroke(.fixture(layerID: project.layers[0].id, points: []))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidStrokePointCount(project.commands[0].id, 0))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        project.commands = [.stroke(.fixture(
            layerID: project.layers[0].id,
            points: Array(repeating: StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0), count: PaintingProject.maximumStrokePointCount + 1)
        ))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidStrokePointCount(
            project.commands[0].id,
            PaintingProject.maximumStrokePointCount + 1
        ))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        project.commands = [.stroke(.fixture(
            layerID: project.layers[0].id,
            points: [
                StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 2),
                StrokePoint(x: 2, y: 2, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
            ]
        ))]
        #expect(throws: DocumentCodecError.validationFailed(.nonMonotonicStrokeTime(project.commands[0].id, 1))) {
            _ = try PaintingDocumentCodec.encode(project)
        }
    }

    @Test func codecRejectsUnboundedDryingAndBrokenIdentifiers() throws {
        var project = PaintingProject.newDefault()
        let layerID = project.layers[0].id
        project.commands = [.dryLayer(DryLayerCommand(layerID: layerID, steps: PaintingProject.maximumDryStepCount + 1))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidDryStepCount(
            project.commands[0].id,
            PaintingProject.maximumDryStepCount + 1
        ))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        let duplicateID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        project.commands = [
            .clearLayer(LayerCommand(id: duplicateID, layerID: layerID)),
            .dryLayer(DryLayerCommand(id: duplicateID, layerID: layerID, steps: 1))
        ]
        #expect(throws: DocumentCodecError.validationFailed(.duplicateCommandIdentifier(duplicateID))) {
            _ = try PaintingDocumentCodec.encode(project)
        }

        project.commands = [.mergeDown(MergeDownCommand(sourceLayerID: layerID, destinationLayerID: layerID))]
        #expect(throws: DocumentCodecError.validationFailed(.invalidCommandRelationship(project.commands[0].id))) {
            _ = try PaintingDocumentCodec.encode(project)
        }
    }

    @Test func codecPreservesMaximumDryStepsWithoutClamping() throws {
        var project = PaintingProject.newDefault()
        project.commands = [.dryLayer(DryLayerCommand(
            layerID: project.layers[0].id,
            steps: PaintingProject.maximumDryStepCount
        ))]

        let decoded = try PaintingDocumentCodec.decode(PaintingDocumentCodec.encode(project))
        guard case let .dryLayer(dry) = try #require(decoded.commands.first) else {
            Issue.record("Expected the dry command to survive the document round trip")
            return
        }

        #expect(dry.steps == PaintingProject.maximumDryStepCount)
    }
}

private struct SchemaVersionFixture: Decodable {
    let schemaVersion: Int
}

private let dynamicBrushKeys = [
    "behaviorVersion",
    "spacing",
    "rotation",
    "bristleStrength",
    "textureStrength"
]

private func replacingBrushDynamics(
    in data: Data,
    with replacements: [String: Any],
    removingExistingDynamics: Bool = false
) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let replaced = replaceBrushDynamics(
        in: object,
        with: replacements,
        removingExistingDynamics: removingExistingDynamics
    )
    return try JSONSerialization.data(withJSONObject: replaced, options: [.sortedKeys])
}

private func replaceBrushDynamics(
    in value: Any,
    with replacements: [String: Any],
    removingExistingDynamics: Bool
) -> Any {
    if let array = value as? [Any] {
        return array.map {
            replaceBrushDynamics(
                in: $0,
                with: replacements,
                removingExistingDynamics: removingExistingDynamics
            )
        }
    }
    guard var dictionary = value as? [String: Any] else { return value }

    if dictionary["shape"] != nil,
       dictionary["hair"] != nil,
       dictionary["texture"] != nil,
       dictionary["style"] != nil {
        if removingExistingDynamics {
            for key in dynamicBrushKeys {
                dictionary.removeValue(forKey: key)
            }
        }
        for (key, replacement) in replacements {
            dictionary[key] = replacement
        }
        return dictionary
    }

    for (key, nested) in dictionary {
        dictionary[key] = replaceBrushDynamics(
            in: nested,
            with: replacements,
            removingExistingDynamics: removingExistingDynamics
        )
    }
    return dictionary
}

private extension PaintingCommand {
    var stroke: StrokeCommand? {
        guard case let .stroke(stroke) = self else { return nil }
        return stroke
    }
}

private extension StrokeCommand {
    static func fixture(
        layerID: UUID,
        brush: BrushSettings = .default,
        points: [StrokePoint] = [StrokePoint(x: 10, y: 20, pressure: 0.8, tiltX: 0.1, tiltY: -0.2, time: 1)]
    ) -> Self {
        Self(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: points
        )
    }
}

private extension PaintingProject {
    static func pointLimitFixture(pointCount: Int, point: StrokePoint) -> Self {
        var project = Self.newDefault()
        let fullStrokeCount = pointCount / Self.maximumStrokePointCount
        let remainderPointCount = pointCount % Self.maximumStrokePointCount
        let fullStrokePoints = Array(repeating: point, count: Self.maximumStrokePointCount)
        let historicalLayerID = UUID()
        project.commands = (0..<fullStrokeCount).map { _ in
            .stroke(StrokeCommand(
                layerID: historicalLayerID,
                tool: .brush,
                brush: .default,
                points: fullStrokePoints
            ))
        }
        if remainderPointCount > 0 {
            project.commands.append(.stroke(StrokeCommand(
                layerID: historicalLayerID,
                tool: .brush,
                brush: .default,
                points: Array(repeating: point, count: remainderPointCount)
            )))
        }
        return project
    }
}
