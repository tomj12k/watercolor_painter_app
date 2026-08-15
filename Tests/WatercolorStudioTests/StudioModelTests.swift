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
        id: UUID = UUID(uuidString: "364E8548-E972-4B33-AC9B-CB7977A89AF3")!,
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
