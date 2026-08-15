import Foundation
import Metal
import MetalKit
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite @MainActor struct StudioModelTests {
    @Test func initialStateReflectsTheProjectAndStudioDefaults() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)

        let model = StudioModel(project: project, renderer: renderer)

        #expect(model.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.selectedTool == .brush)
        #expect(model.brush == .default)
        #expect(model.zoom == 1)
        #expect(model.pan == .zero)
        #expect(model.error == nil)
        #expect(model.capabilities == StudioCapabilities(canPaint: true, canUndo: false, canRedo: false))
    }

    @Test func completedStrokeUpdatesProjectDocumentAndCapabilities() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)

        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(model.error == nil)
    }

    @Test func canvasWetnessReflectsCompletedStrokesAndProjectReplay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var waterStroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        waterStroke.tool = .water

        #expect(model.canvasWetness == 0)

        model.completeStroke(waterStroke)
        #expect(model.canvasWetness > 0.1)

        model.clearSelectedLayer()
        #expect(model.canvasWetness == 0)
    }

    @Test func selectingAnUnknownLayerDisablesNewPaintingButPreservesAnInFlightStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        model.selectedLayerID = UUID(uuidString: "187C458F-D40D-427D-970F-3E7A40FD301B")!
        model.completeStroke(stroke)

        #expect(!model.capabilities.canPaint)
        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdateCount == 1)
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 128, y: 128).alpha > 0.05)
    }

    @Test func completedStrokeTargetsThePointerDownLayerAfterSelectionChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let otherLayer = PaintLayer(
            id: UUID(uuidString: "0CD27F43-E900-467A-B7CB-D21A7B966681")!,
            name: "Other"
        )
        project.layers.append(otherLayer)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        model.selectedLayerID = otherLayer.id
        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdateCount == 1)
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id).alpha > 0.05)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: otherLayer.id).alpha == 0)
    }

    @Test func completedStrokeFailureDoesNotPersistTheCommand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "deterministic GPU execution failure"]
        )
        var failedBuffer: MTLCommandBuffer?
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if failedBuffer == nil, commandBuffer.label == "Watercolor stroke" {
                    failedBuffer = commandBuffer
                }
                guard let failedBuffer, commandBuffer === failedBuffer else {
                    return commandBuffer.error
                }
                return injectedError
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let checksumBefore = try renderer.studioChecksum()
        let failedStroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "89204F9E-83C1-45F2-A9E7-4850732544AA")!,
            layerID: project.layers[0].id,
            x: 64,
            y: 64
        )

        model.completeStroke(failedStroke)

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(model.error?.message.contains("deterministic GPU execution failure") == true)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha == 0)

        let validStroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "664296E0-1872-47D9-9A08-E2FCFCB5DC80")!,
            layerID: project.layers[0].id,
            x: 192,
            y: 192
        )
        model.completeStroke(validStroke)

        #expect(model.project.commands == [.stroke(validStroke)])
        #expect(documentUpdates == [model.project])
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha == 0)
        #expect(try renderer.debugPixel(x: 192, y: 192).alpha > 0.1)
    }

    @Test func configuringACanvasAttachesOnlyTheDisplayDelegate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let view = MTKView(frame: .zero)

        model.configureCanvas(view)

        #expect(view.device === device)
        #expect(view.colorPixelFormat == .bgra8Unorm)
        #expect(view.delegate != nil)
        #expect(view.delegate !== renderer)
        view.delegate?.mtkView(view, drawableSizeWillChange: CGSize(width: 320, height: 240))
        #expect(renderer.viewportSize == CGSize(width: 320, height: 240))
    }

    @Test func displayStateUpdatesInvalidateWithoutReattachingCanvasConfiguration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let view = InvalidatingMTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        model.configureCanvas(view)
        view.delegate = nil
        view.colorPixelFormat = .rgba8Unorm
        view.invalidationCount = 0

        model.zoom = 2
        model.pan = CGSize(width: 10, height: 20)
        model.updateCanvasDisplay(view)

        #expect(view.delegate == nil)
        #expect(view.colorPixelFormat == .rgba8Unorm)
        #expect(view.device === device)
        #expect(view.invalidationCount == 1)
    }

    @Test func renderFailurePreservesTheProjectAndReportsTheError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )
        let missingLayerID = UUID(uuidString: "DC0B6B55-5763-43B1-A8E9-73F5CCBBE79B")!

        model.completeStroke(.studioTestStroke(layerID: missingLayerID))

        #expect(model.project == project)
        #expect(documentUpdateCount == 0)
        #expect(model.error?.message.contains(missingLayerID.uuidString) == true)
        #expect(!model.capabilities.canUndo)
    }

    @Test func addingALayerSelectsItAndPublishesTheReplayedProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.addLayer()

        #expect(model.project.layers.map(\.name) == ["Layer 1", "Layer 2"])
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.rendererProject == model.project)
        #expect(renderer.project == project)
        #expect(documentUpdates == [model.project])
        #expect(model.error == nil)
        #expect(model.capabilities.canUndo)
    }

    @Test func duplicatingTheSelectedLayerSelectsTheCopy() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.layers[0].isVisible = false
        project.layers[0].opacity = 0.45
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.duplicateSelectedLayer()

        #expect(model.project.layers.count == 2)
        #expect(model.project.layers[1].name == "Layer 1 copy")
        #expect(model.project.layers[1].isVisible == false)
        #expect(model.project.layers[1].opacity == 0.45)
        #expect(model.project.layers[1].id != project.layers[0].id)
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func deletingTheSelectedLayerKeepsSelectionValid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        model.selectedLayerID = middle.id

        model.deleteSelectedLayer()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id, top.id])
        #expect(model.selectedLayerID == top.id)
        #expect(model.capabilities.canPaint)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func movingTheSelectedLayerUpChangesItsStackPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.moveSelectedLayerUp()

        #expect(model.project.layers.map(\.id) == [middle.id, project.layers[0].id, top.id])
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func movingTheSelectedLayerDownChangesItsStackPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.selectedLayerID = top.id

        model.moveSelectedLayerDown()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id, top.id, middle.id])
        #expect(model.selectedLayerID == top.id)
        #expect(model.rendererProject == model.project)
    }

    @Test func renamingALayerPublishesATrimmedNonemptyName() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.renameLayer(id: project.layers[0].id, to: "  Sky wash  ")

        #expect(model.project.layers[0].name == "Sky wash")
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func changingLayerVisibilityPublishesTheReplayedCompositeMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.setLayerVisibility(id: project.layers[0].id, isVisible: false)

        #expect(model.project.layers[0].isVisible == false)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func metadataEditsReuseTheRendererAndCommitHistoryAndDocumentOnceEach() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let top = PaintLayer(name: "Top")
        project.layers.append(top)
        project.commands = [
            .stroke(.studioTestStroke(layerID: project.layers[0].id, x: 112, y: 128)),
            .stroke(.studioTestStroke(layerID: top.id, x: 144, y: 128))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let rendererIdentity = ObjectIdentifier(renderer)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.renameLayer(id: project.layers[0].id, to: "Ground")
        model.setLayerVisibility(id: project.layers[0].id, isVisible: false)
        model.moveSelectedLayerUp()
        model.previewLayerOpacity(id: top.id, opacity: 0.35)
        model.commitLayerOpacity(id: top.id)

        #expect(model.rendererIdentity == rendererIdentity)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates.count == 4)
        #expect(model.capabilities.canUndo)
        #expect(model.project.layers.first(where: { $0.id == top.id })?.opacity == 0.35)
    }

    @Test func changingLayerOpacityClampsItToTheRenderersSupportedRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.setLayerOpacity(id: project.layers[0].id, opacity: 1.5)
        #expect(model.project.layers[0].opacity == 1)
        #expect(model.rendererProject.layers[0].opacity == 1)

        model.setLayerOpacity(id: project.layers[0].id, opacity: -0.25)
        #expect(model.project.layers[0].opacity == 0)
        #expect(model.rendererProject.layers[0].opacity == 0)
    }

    @Test func opacityGesturePreviewsManyValuesAndCommitsOneProjectEdit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let layerID = project.layers[0].id

        model.previewLayerOpacity(id: layerID, opacity: 0.8)
        model.previewLayerOpacity(id: layerID, opacity: 0.5)
        model.previewLayerOpacity(id: layerID, opacity: 0.2)

        #expect(model.displayedLayerOpacity(id: layerID) == 0.2)
        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)

        model.commitLayerOpacity(id: layerID)

        #expect(model.displayedLayerOpacity(id: layerID) == 0.2)
        #expect(model.project.layers[0].opacity == 0.2)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)

        model.commitLayerOpacity(id: layerID)
        #expect(documentUpdates.count == 1)
    }

    @Test func failedOpacityCommitRestoresTheCommittedRendererPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.commands = [.stroke(.studioTestStroke(layerID: project.layers[0].id))]
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "persistent opacity commit failure"]
        )
        var shouldFail = false
        var failedMetadataCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Apply layer metadata" {
                    failedMetadataCount += 1
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
        let layerID = project.layers[0].id
        let committedChecksum = try renderer.studioChecksum()
        model.previewLayerOpacity(id: layerID, opacity: 0.1)
        #expect(try renderer.studioChecksum() != committedChecksum)
        shouldFail = true

        model.commitLayerOpacity(id: layerID)

        #expect(model.project == project)
        #expect(model.displayedLayerOpacity(id: layerID) == 1)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == committedChecksum)
        #expect(failedMetadataCount == 1)
        #expect(model.error?.message.contains("persistent opacity commit failure") == true)
    }

    @Test func changingLayerOpacityIgnoresANonfiniteValue() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.setLayerOpacity(id: project.layers[0].id, opacity: .nan)

        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(documentUpdates.isEmpty)
    }

    @Test func mergingTheSelectedLayerDownSelectsTheDestinationLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let top = PaintLayer(name: "Top")
        project.layers.append(top)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        model.selectedLayerID = top.id

        model.mergeSelectedLayerDown()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id])
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.project.commands.count == 1)
        if case let .mergeDown(command) = model.project.commands[0] {
            #expect(command.sourceLayerID == top.id)
            #expect(command.destinationLayerID == project.layers[0].id)
        } else {
            Issue.record("Expected a merge-down command")
        }
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func clearingTheSelectedLayerRecordsAndReplaysTheCommand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.clearSelectedLayer()

        #expect(model.project.commands.count == 1)
        if case let .clearLayer(command) = model.project.commands[0] {
            #expect(command.layerID == project.layers[0].id)
        } else {
            Issue.record("Expected a clear-layer command")
        }
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func selectingPaperPublishesAndReplaysTheProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(.rough)

        #expect(model.project.paper == .rough)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func changingPaperReplaysPaintedRasterExactlyAsTheSavedProjectReopens() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        project.commands = [.stroke(stroke)]
        let originalRenderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: originalRenderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(.rough)

        let reopenedProject = try PaintingDocumentCodec.decode(
            PaintingDocumentCodec.encode(model.project)
        )
        let reopenedRenderer = try WatercolorRenderer(project: reopenedProject, device: device)
        let liveRenderer = model.rendererForTesting
        #expect(model.project == reopenedProject)
        #expect(liveRenderer.project == reopenedProject)
        #expect(
            try liveRenderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
                == reopenedRenderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
        )
        #expect(
            try liveRenderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
                == reopenedRenderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
        )
        #expect(try liveRenderer.studioChecksum() == reopenedRenderer.studioChecksum())
        #expect(model.canvasWetness == reopenedRenderer.canvasWetness)
        #expect(model.rendererIdentity != ObjectIdentifier(originalRenderer))
        #expect(liveRenderer.debugResources.pipelines == originalRenderer.debugResources.pipelines)
        #expect(documentUpdates == [model.project])
    }

    @Test func selectingTheCurrentPaperDoesNotPublishANoOpEdit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(project.paper)

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
    }

    @Test func failedPaperReplayPreservesTheLiveModelRendererAndDocument() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.commands = [
            .stroke(.studioTestStroke(layerID: project.layers[0].id))
        ]
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "deterministic paper replay failure"]
        )
        var shouldFail = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Watercolor replay" {
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
        let rendererIdentity = model.rendererIdentity
        let checksum = try renderer.studioChecksum()
        let pigment = try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
        let wetness = try renderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
        let canvasWetness = model.canvasWetness
        shouldFail = true

        model.selectPaper(.rough)

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(model.rendererIdentity == rendererIdentity)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == checksum)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id) == pigment)
        #expect(try renderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id) == wetness)
        #expect(model.canvasWetness == canvasWetness)
        #expect(model.error?.message.contains("deterministic paper replay failure") == true)
        #expect(failedReplayCount == 1)
    }

    @Test func brushSizeAdjustmentsStayWithinThePaintableRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.adjustBrushSize(by: -100)
        #expect(model.brush.size == 1)

        model.adjustBrushSize(by: 1_000)
        #expect(model.brush.size == 300)
    }

    @Test func selectingAStyleAppliesItsWatercolorParameters() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.brush.color = PaintColor(red: 0.1, green: 0.2, blue: 0.3)
        model.brush.shape = .fan

        model.selectStyle(.wetOnWet)

        #expect(model.brush.style == .wetOnWet)
        #expect(model.brush.opacity == 0.3)
        #expect(model.brush.flow == 0.5)
        #expect(model.brush.water == 0.9)
        #expect(model.brush.edgeBloom == 0.8)
        #expect(model.brush.shape == .fan)
        #expect(model.brush.color == PaintColor(red: 0.1, green: 0.2, blue: 0.3))
    }

    @Test func toolShortcutsSelectEveryPaintingTool() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let cases: [(String, PaintTool)] = [
            ("B", .brush),
            ("e", .eraser),
            ("W", .water),
            ("s", .smudge),
            ("M", .smear),
            ("d", .dry)
        ]

        for (shortcut, expectedTool) in cases {
            #expect(model.selectTool(forShortcut: shortcut))
            #expect(model.selectedTool == expectedTool)
        }

        #expect(!model.selectTool(forShortcut: "x"))
        #expect(model.selectedTool == .dry)
    }

    @Test func fittingTheCanvasRestoresTheAspectFitViewport() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.zoom = 4.25
        model.pan = CGSize(width: 120, height: -45)

        model.fitCanvas()

        #expect(model.zoom == 1)
        #expect(model.pan == .zero)
    }

    @Test func unavailableFocusedCommandsAreSilentNoOps() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.undo()
        model.redo()
        model.selectedLayerID = UUID()
        model.drySelectedLayer()
        #expect(model.project == project)
    }

    @Test func layerActionAvailabilityReflectsSelectionAndLayerLimits() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        #expect(model.canAddLayer)
        #expect(model.canDuplicateSelectedLayer)
        #expect(!model.canDeleteSelectedLayer)
        #expect(!model.canMoveSelectedLayerUp)
        #expect(!model.canMoveSelectedLayerDown)
        #expect(!model.canMergeSelectedLayerDown)

        model.selectedLayerID = UUID()
        #expect(!model.canDuplicateSelectedLayer)
    }

    @Test func duplicationRemainsAvailableAfterManyHistoricalDuplicateDeleteCycles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = PaintLayer(name: "Generation 0")
        var editor = ProjectEditor(project: PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [firstLayer],
            commands: [.stroke(.studioTestStroke(layerID: firstLayer.id))]
        ))
        for generation in 1...16 {
            let sourceID = try #require(editor.project.layers.first?.id)
            try editor.duplicateLayer(id: sourceID, named: "Generation \(generation)")
            try editor.removeLayer(id: sourceID)
        }
        let renderer = try WatercolorRenderer(project: editor.project, device: device)
        let model = StudioModel(project: editor.project, renderer: renderer)

        #expect(model.canDuplicateSelectedLayer)
        model.duplicateSelectedLayer()

        #expect(model.project.layers.count == 2)
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.error == nil)
    }

    @Test func dismissingTheAlertClearsTheIdentifiableFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.completeStroke(.studioTestStroke(layerID: UUID()))
        #expect(model.error != nil)

        model.dismissError()

        #expect(model.error == nil)
    }

    @Test func failedStructuralReplayPreservesModelRendererSelectionAndDocument() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "deterministic structural replay failure"]
        )
        var shouldFail = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Watercolor replay" {
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
        shouldFail = true

        model.addLayer()

        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(model.error?.message.contains("deterministic structural replay failure") == true)
        #expect(failedReplayCount == 1)
    }
}

@MainActor
private final class InvalidatingMTKView: MTKView {
    var invalidationCount = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidationCount += 1
        super.setNeedsDisplay(invalidRect)
    }
}

private extension PaintingProject {
    static func studioTestProject() -> Self {
        Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "F63BBA2D-81C1-4ABF-B0D4-99B3F8D63B8C")!,
                    name: "Layer 1"
                )
            ]
        )
    }
}

private extension StrokeCommand {
    static func studioTestStroke(
        id: UUID = UUID(),
        layerID: UUID,
        x: Double = 128,
        y: Double = 128
    ) -> Self {
        Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}

private extension WatercolorRenderer {
    func studioChecksum() throws -> UInt64 {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The test could not access image bytes")
        }
        return (0..<CFDataGetLength(data)).reduce(UInt64(0)) { checksum, index in
            (checksum &* 16_777_619) ^ UInt64(bytes[index])
        }
    }
}
