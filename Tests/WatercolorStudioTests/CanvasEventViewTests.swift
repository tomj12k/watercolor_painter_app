import AppKit
import CoreGraphics
import Foundation
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite struct CanvasStrokeBuilderTests {
    @Test func completedStrokeSnapshotsSettingsAndClampsEveryInput() {
        let layerID = UUID(uuidString: "75C15CB5-C88E-4F83-B590-578F87DAD64A")!
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))

        builder.begin(
            layerID: layerID,
            tool: .smear,
            brush: brush,
            point: .init(x: -10, y: 1400, pressure: 4, tiltX: -3, tiltY: 2, time: 1)
        )
        let stroke = builder.finish()

        #expect(stroke?.layerID == layerID)
        #expect(stroke?.tool == .smear)
        #expect(stroke?.brush == brush)
        #expect(stroke?.points == [
            StrokePoint(x: 0, y: 1200, pressure: 1, tiltX: -1, tiltY: 1, time: 1)
        ])
    }

    @Test func consecutiveSamplesUseEighteenPercentOfPressureScaledDiameter() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let layerID = UUID(uuidString: "05E428FB-8CE0-40E7-8383-F61B67408BE1")!

        builder.begin(
            layerID: layerID,
            tool: .brush,
            brush: brush,
            point: .init(x: 0, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 0)
        )
        builder.append(.init(x: 18, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 2))

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points.map(\.x) == [0, 9, 18])
        #expect(stroke.points.map(\.time) == [0, 1, 2])
    }

    @Test func duplicateMouseAndTabletSamplesDoNotCreateExtraPointsOrCommands() throws {
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let point = StrokePoint(x: 200, y: 300, pressure: 0.7, tiltX: 0.2, tiltY: -0.1, time: 4)

        builder.begin(layerID: UUID(), tool: .brush, brush: .default, point: point)
        builder.append(point)

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points == [point])
        #expect(builder.finish() == nil)
    }
}

@Suite @MainActor struct CanvasStrokeIntegrationTests {
    @Test func builderStrokeCompletesToItsSnapshottedLayerAfterSelectionChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = PaintLayer(name: "First")
        let secondLayer = PaintLayer(name: "Second")
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [firstLayer, secondLayer]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 256, height: 256))
        builder.begin(
            layerID: model.selectedLayerID,
            tool: model.selectedTool,
            brush: model.brush,
            point: StrokePoint(x: 128, y: 128, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        model.selectedLayerID = secondLayer.id
        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: firstLayer.id).alpha > 0.05)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: secondLayer.id).alpha == 0)
    }

    @Test func replacingTheStudioModelReattachesOnceAndTransfersDisplayAndInputOwnership() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let oldLayer = PaintLayer(name: "Old")
        let newLayer = PaintLayer(name: "New")
        let oldProject = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [oldLayer]
        )
        let newProject = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [newLayer]
        )
        let oldRenderer = try WatercolorRenderer(project: oldProject, device: device)
        let newRenderer = try WatercolorRenderer(project: newProject, device: device)
        let oldModel = StudioModel(project: oldProject, renderer: oldRenderer)
        let newModel = StudioModel(project: newProject, renderer: newRenderer)
        let view = CanvasEventView(model: oldModel)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)

        oldModel.configureCanvas(view)
        let oldDelegate = try #require(view.delegate)
        oldDelegate.mtkView(view, drawableSizeWillChange: CGSize(width: 100, height: 100))
        view.synchronize(with: oldModel)
        #expect(view.delegate === oldDelegate)
        view.mouseDown(with: try #require(canvasMouseEvent(.leftMouseDown, timestamp: 0, eventNumber: 0)))

        newModel.zoom = 2
        newModel.pan = CGSize(width: 12, height: -8)
        view.synchronize(with: newModel)
        let newDelegate = try #require(view.delegate)
        #expect(newDelegate !== oldDelegate)
        newDelegate.mtkView(view, drawableSizeWillChange: CGSize(width: 200, height: 150))
        #expect(oldRenderer.viewportSize == CGSize(width: 100, height: 100))
        #expect(newRenderer.viewportSize == CGSize(width: 200, height: 150))
        view.mouseUp(with: try #require(canvasMouseEvent(.leftMouseUp, timestamp: 0.5, eventNumber: 1)))
        #expect(newModel.project.commands.isEmpty)
        #expect(newModel.error == nil)

        view.synchronize(with: newModel)
        #expect(view.delegate === newDelegate)

        let down = try #require(canvasMouseEvent(.leftMouseDown, timestamp: 1, eventNumber: 2))
        let up = try #require(canvasMouseEvent(.leftMouseUp, timestamp: 2, eventNumber: 3))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await waitForStrokePreviewToFinish(in: newModel)

        #expect(oldModel.project.commands.isEmpty)
        #expect(newModel.project.commands.count == 1)
        #expect(try oldRenderer.debugPixel(x: 128, y: 128, layerID: oldLayer.id).alpha == 0)
        #expect(try newRenderer.debugPixel(x: 128, y: 128, layerID: newLayer.id).alpha > 0.05)
    }
}

@MainActor
private func waitForStrokePreviewToFinish(in model: StudioModel) async {
    for _ in 0..<1_000 where model.isStrokePreviewActive {
        await Task.yield()
    }
}

@MainActor
private func canvasMouseEvent(
    _ type: NSEvent.EventType,
    timestamp: TimeInterval,
    eventNumber: Int
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: CGPoint(x: 128, y: 128),
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: 0,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 1
    )
}
