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

    @Test func consecutiveSamplesUseEighteenPercentOfBrushDiameter() throws {
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
        _ = builder.append(.init(x: 18, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 2))

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points.map(\.x) == [0, 18])
        #expect(stroke.points.map(\.time) == [0, 2])
    }

    @Test func equivalentCoarseAndFineEventsProduceTheSameGeometricStroke() throws {
        var brush = BrushSettings.default
        brush.size = 100
        let start = StrokePoint(x: 0, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 0)
        let end = StrokePoint(x: 100, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 10)

        var coarse = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        coarse.begin(layerID: UUID(), tool: .brush, brush: brush, point: start)
        _ = coarse.append(end)

        var fine = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        fine.begin(layerID: UUID(), tool: .brush, brush: brush, point: start)
        for x in 1...100 {
            _ = fine.append(StrokePoint(
                x: Double(x), y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: Double(x) / 10
            ))
        }

        let coarseResult = coarse.finish()
        let fineResult = fine.finish()
        let coarseStroke = try #require(coarseResult)
        let fineStroke = try #require(fineResult)
        #expect(coarseStroke.points.map(\.x) == fineStroke.points.map(\.x))
    }

    @Test func pressureDoesNotChangeSamplingCount() throws {
        var brush = BrushSettings.default
        brush.size = 100

        var noPressure = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        noPressure.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 100, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = noPressure.append(.init(x: 100, y: 100, pressure: 0, tiltX: 0, tiltY: 0, time: 1))

        var fullPressure = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        fullPressure.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 100, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = fullPressure.append(.init(x: 100, y: 100, pressure: 1, tiltX: 0, tiltY: 0, time: 1))

        let noPressureResult = noPressure.finish()
        let fullPressureResult = fullPressure.finish()
        let noPressureStroke = try #require(noPressureResult)
        let fullPressureStroke = try #require(fullPressureResult)
        #expect(noPressureStroke.points.count == fullPressureStroke.points.count)
    }

    @Test func sizeOneStrokeNeverStoresMoreThanTheDurablePointLimit() throws {
        var brush = BrushSettings.default
        brush.size = 1
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 100_000, height: 100))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        let appendResult = builder.append(
            .init(x: 50_000, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        let stroke = try #require(builder.currentStroke)
        #expect(stroke.points.count == PaintingProject.maximumStrokePointCount)
        #expect(appendResult.points.count == PaintingProject.maximumStrokePointCount - 1)
        #expect(appendResult.isExhausted)
        let completion = builder.finish(at: nil)
        #expect(completion.isExhausted)
    }

    @Test func duplicateMouseAndTabletSamplesDoNotCreateExtraPointsOrCommands() throws {
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let point = StrokePoint(x: 200, y: 300, pressure: 0.7, tiltX: 0.2, tiltY: -0.1, time: 4)

        builder.begin(layerID: UUID(), tool: .brush, brush: .default, point: point)
        _ = builder.append(point)

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points == [point])
        #expect(builder.finish() == nil)
    }

    @Test func finishingAddsThePointerUpEndpointOnceAfterASubpixelPath() throws {
        var brush = BrushSettings.default
        brush.size = 1
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 10, y: 10, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        )

        let completion = builder.finish(at: .init(
            x: 10.25, y: 10, pressure: 1, tiltX: 0.5, tiltY: -0.5, time: 1
        ))
        let stroke = try #require(completion.stroke)

        #expect(!completion.isExhausted)
        #expect(stroke.points.map(\.x) == [10, 10.25])
        #expect(stroke.points.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite
                && $0.tiltX.isFinite && $0.tiltY.isFinite && $0.time.isFinite
        })
    }

    @Test func zeroContactUpdatesDoNotCreateSimulationPoints() throws {
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: .default,
            point: .init(x: 200, y: 300, pressure: 0.2, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = builder.append(.init(x: 200, y: 300, pressure: 1, tiltX: 1, tiltY: -1, time: 1))

        let completion = builder.finish(at: nil)
        let stroke = try #require(completion.stroke)
        #expect(stroke.points.count == 1)
    }
}

@Suite @MainActor struct CanvasEventViewTests {
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

    @Test func losingFocusClearsSpacePanAndCancelsTransientStrokeState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)
        let space = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        view.keyDown(with: space)
        view.mouseDown(with: try #require(canvasMouseEvent(.leftMouseDown, timestamp: 0, eventNumber: 0)))
        #expect(view.hasTransientInputStateForTesting)

        _ = view.resignFirstResponder()

        #expect(!view.hasTransientInputStateForTesting)
        #expect(!model.isStrokePreviewActive)
    }

    @Test func rejectedPreviewAdmissionDoesNotBuildStroke() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let finish = CanvasPreviewSuspension()
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, stroke, token in
                    try await renderer.updateStrokePreview(stroke, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    await finish.suspend()
                }
            )
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)
        let first = StrokeCommand(
            layerID: project.layers[0].id,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 64, y: 64, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )

        #expect(model.beginStrokePreview(first) == .accepted)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(first)
        }
        await finish.waitUntilSuspended()
        view.synchronize(with: model)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 1,
            eventNumber: 1
        )))

        #expect(!view.hasTransientInputStateForTesting)
        #expect(view.toolTip == "Finishing stroke.")

        await finish.resume()
        await commit.value
        #expect(model.project.commands == [.stroke(first)])
    }
}

private actor CanvasPreviewSuspension {
    private var isSuspended = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            completion = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        completion?.resume()
        completion = nil
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
