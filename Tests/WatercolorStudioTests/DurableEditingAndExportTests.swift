import Foundation
import ImageIO
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite @MainActor struct DurableEditingAndExportTests {
    @Test func undoAndRedoReplayStrokePixelsAndPublishEachProjectOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let blankChecksum = try renderer.pixelChecksum()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let stroke = StrokeCommand.durableFixture(layerID: project.layers[0].id)
        model.completeStroke(stroke)
        let paintedProject = model.project
        let paintedChecksum = try model.rendererForTesting.pixelChecksum()

        model.undo()

        #expect(model.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == project)
        #expect(try model.rendererForTesting.pixelChecksum() == blankChecksum)
        #expect(!model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)

        model.redo()

        #expect(model.project == paintedProject)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == paintedProject)
        #expect(try model.rendererForTesting.pixelChecksum() == paintedChecksum)
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project, paintedProject])
    }

    @Test func persistentUndoAndRedoReplayFailurePreservesLiveStateAndHistory() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let injectedError = NSError(
            domain: "DurableEditingAndExportTests",
            code: 31,
            userInfo: [NSLocalizedDescriptionKey: "persistent undo replay failure"]
        )
        var shouldFailReplay = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailReplay, commandBuffer.label == "Watercolor replay" {
                    failedReplayCount += 1
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        model.completeStroke(.durableFixture(layerID: project.layers[0].id))
        let paintedProject = model.project
        let paintedRendererIdentity = model.rendererIdentity
        let paintedChecksum = try renderer.pixelChecksum()
        shouldFailReplay = true

        model.undo()
        model.undo()

        #expect(model.project == paintedProject)
        #expect(model.rendererProject == paintedProject)
        #expect(model.rendererIdentity == paintedRendererIdentity)
        #expect(try renderer.pixelChecksum() == paintedChecksum)
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject])
        #expect(failedReplayCount == 2)
        #expect(model.error?.message.contains("persistent undo replay failure") == true)

        shouldFailReplay = false
        model.undo()

        #expect(model.project == project)
        #expect(model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project])

        let undoneRendererIdentity = model.rendererIdentity
        let undoneChecksum = try model.rendererForTesting.pixelChecksum()
        shouldFailReplay = true
        model.redo()
        model.redo()

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(model.rendererIdentity == undoneRendererIdentity)
        #expect(try model.rendererForTesting.pixelChecksum() == undoneChecksum)
        #expect(!model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project])
        #expect(failedReplayCount == 4)

        shouldFailReplay = false
        model.redo()
        #expect(model.project == paintedProject)
        #expect(documentUpdates == [paintedProject, project, paintedProject])
    }

    @Test func drySelectedLayerAppendsOneFixedCommandAndDecreasesLiveWetness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.durableFixture()
        var wetStroke = StrokeCommand.durableFixture(layerID: project.layers[0].id)
        wetStroke.tool = .water
        project.commands = [.stroke(wetStroke)]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let wetnessBefore = renderer.canvasWetness
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.drySelectedLayer()

        #expect(model.project.commands.count == 2)
        guard case let .dryLayer(command) = model.project.commands.last else {
            Issue.record("Expected one durable dry-layer command")
            return
        }
        #expect(command.layerID == project.layers[0].id)
        #expect(command.steps == 24)
        #expect(model.canvasWetness < wetnessBefore)
        #expect(model.canvasWetness == model.rendererForTesting.canvasWetness)
        #expect(documentUpdates == [model.project])
    }

    @Test func mergeCommandSurvivesUndoRedoSaveAndReopen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.durableFixture(layerID: bottom.id, x: 112)),
            .stroke(.durableFixture(layerID: top.id, x: 144))
        ]
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        model.selectedLayerID = top.id

        model.mergeSelectedLayerDown()
        let mergedProject = model.project
        let mergedChecksum = try model.rendererForTesting.pixelChecksum()
        guard case let .mergeDown(merge) = mergedProject.commands.last else {
            Issue.record("Expected a semantic merge command")
            return
        }
        #expect(merge.sourceLayerID == top.id)
        #expect(merge.destinationLayerID == bottom.id)

        model.undo()
        #expect(model.project == project)
        #expect(project.layers.contains(where: { $0.id == model.selectedLayerID }))

        model.redo()
        #expect(model.project == mergedProject)
        #expect(model.selectedLayerID == bottom.id)
        #expect(try model.rendererForTesting.pixelChecksum() == mergedChecksum)

        let reopened = try PaintingDocumentCodec.decode(PaintingDocumentCodec.encode(mergedProject))
        let reopenedRenderer = try WatercolorRenderer(project: reopened, device: device)
        #expect(reopened == mergedProject)
        #expect(try reopenedRenderer.pixelChecksum() == mergedChecksum)
    }

    @Test func pngExportWritesFinalCanvasWithoutMutatingTheProjectOrHistory() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.durableFixture()
        project.commands = [.stroke(.durableFixture(layerID: project.layers[0].id))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let rendererIdentity = model.rendererIdentity
        let wetness = model.canvasWetness
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("final.png")

        await model.exportPNG(to: destination)

        let data = try Data(contentsOf: destination)
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == project.canvas.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == project.canvas.height)
        #expect(model.project == project)
        #expect(model.rendererIdentity == rendererIdentity)
        #expect(model.canvasWetness == wetness)
        #expect(!model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates.isEmpty)
        #expect(model.error == nil)
    }

    @Test func failedPNGExportPreservesAnExistingDestinationAndReportsFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: directory.path
        )

        await model.exportPNG(to: destination)

        #expect(try Data(contentsOf: destination) == original)
        #expect(model.project == project)
        #expect(model.error?.message.contains("existing.png") == true)
        #expect(model.error?.id != nil)
    }
}

private extension PaintingProject {
    static func durableFixture() -> Self {
        Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "9CF9177D-247F-41FA-9529-165972589761")!,
                    name: "Layer 1"
                )
            ]
        )
    }
}

private extension StrokeCommand {
    static func durableFixture(
        layerID: UUID,
        x: Double = 128,
        y: Double = 128
    ) -> Self {
        var brush = BrushSettings.default
        brush.color = PaintColor(red: 0.8, green: 0.2, blue: 0.1)
        brush.opacity = 0.8
        brush.flow = 0.8
        return Self(
            id: UUID(uuidString: "13D32B90-B1B6-4446-B057-B26D44BC64D2")!,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: [StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}
