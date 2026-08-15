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

    @Test func selectingAnUnknownLayerDisablesPaintingAndRejectsAStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        model.selectedLayerID = UUID(uuidString: "187C458F-D40D-427D-970F-3E7A40FD301B")!
        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))

        #expect(!model.capabilities.canPaint)
        #expect(model.project == project)
        #expect(documentUpdateCount == 0)
        #expect(model.error != nil)
        #expect(try renderer.debugPixel(x: 128, y: 128).alpha == 0)
    }

    @Test func strokeLayerMustMatchTheSelectedLayer() throws {
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

        model.completeStroke(.studioTestStroke(layerID: otherLayer.id))

        #expect(model.project == project)
        #expect(documentUpdateCount == 0)
        #expect(model.error?.message.contains(otherLayer.id.uuidString) == true)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: otherLayer.id).alpha == 0)
    }

    @Test func completedStrokeFailureDoesNotPersistTheCommand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            completedStrokeCheck: { _ in
                throw RendererError.allocation("deterministic completed-stroke failure")
            }
        )
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))

        #expect(model.project == project)
        #expect(documentUpdateCount == 0)
        #expect(model.error?.message.contains("deterministic completed-stroke failure") == true)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.debugPixel(x: 128, y: 128).alpha == 0)
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
    static func studioTestStroke(layerID: UUID) -> Self {
        Self(
            id: UUID(uuidString: "364E8548-E972-4B33-AC9B-CB7977A89AF3")!,
            layerID: layerID,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 128, y: 128, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}
