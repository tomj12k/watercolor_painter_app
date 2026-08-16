import AppKit
import CoreGraphics
import Foundation
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite struct CanvasStrokeBuilderTests {
    @Test func appendReturnsOnlyNewInterpolatedPoints() {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 512, height: 512))
        builder.begin(
            layerID: UUID(uuidString: "3131E50F-DCB4-4AB2-8582-0103F650D030")!,
            tool: .brush,
            brush: brush,
            point: StrokePoint(x: 20, y: 40, pressure: 0.25, tiltX: 0, tiltY: 0, time: 0)
        )

        let result = builder.append(
            StrokePoint(x: 56, y: 40, pressure: 0.75, tiltX: 0.4, tiltY: -0.2, time: 2)
        )

        #expect(result.points == [
            StrokePoint(x: 38, y: 40, pressure: 0.5, tiltX: 0.2, tiltY: -0.1, time: 1),
            StrokePoint(x: 56, y: 40, pressure: 0.75, tiltX: 0.4, tiltY: -0.2, time: 2)
        ])
        #expect(builder.currentStroke?.points.count == 3)
    }

    @Test func longBurstAppendsInPlaceWithoutRelocatingTheReservedPointBuffer() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(
            canvasSize: .init(width: 4096, height: 256),
            maximumPointCount: 256
        )
        builder.begin(
            layerID: UUID(),
            tool: .brush,
            brush: brush,
            point: StrokePoint(x: 0, y: 128, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        let pointStorageIdentity = try #require(builder.pointStorageIdentityForTesting)

        for index in 1...200 {
            let append = builder.append(StrokePoint(
                x: Double(index * 18),
                y: 128,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            ))
            #expect(append.points.count == 1)
            #expect(!append.isExhausted)
            #expect(builder.pointStorageIdentityForTesting == pointStorageIdentity)
        }

        #expect(try #require(builder.currentStroke).points.count == 201)
    }

    @Test func finishReturnsOnlyPointsAddedByThePointerUpEvent() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 512, height: 512))
        builder.begin(
            layerID: UUID(),
            tool: .brush,
            brush: brush,
            point: StrokePoint(x: 20, y: 40, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let result = builder.finish(at: StrokePoint(
            x: 47, y: 40, pressure: 1, tiltX: 0, tiltY: 0, time: 3
        ))

        #expect(result.points == [
            StrokePoint(x: 38, y: 40, pressure: 1, tiltX: 0, tiltY: 0, time: 2),
            StrokePoint(x: 47, y: 40, pressure: 1, tiltX: 0, tiltY: 0, time: 3)
        ])
        #expect(try #require(result.stroke).points.count == 3)
    }

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

    @Test(arguments: [
        (spacing: 0.08, expectedSample: 8.0),
        (spacing: 0.18, expectedSample: 18.0),
        (spacing: 0.60, expectedSample: 60.0)
    ])
    func consecutiveSamplesUseTheSelectedBrushSpacing(
        spacing: Double,
        expectedSample: Double
    ) throws {
        var brush = BrushSettings.default
        brush.size = 100
        brush.spacing = spacing
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let layerID = UUID(uuidString: "05E428FB-8CE0-40E7-8383-F61B67408BE1")!

        builder.begin(
            layerID: layerID,
            tool: .brush,
            brush: brush,
            point: .init(x: 0, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 0)
        )
        let append = builder.append(.init(
            x: expectedSample,
            y: 100,
            pressure: 0.5,
            tiltX: 0,
            tiltY: 0,
            time: 2
        ))

        #expect(append.points.map(\.x) == [expectedSample])
        #expect(append.points.map(\.time) == [2])
    }

    @Test func tinyBrushSpacingUsesThePhysicalThreeQuarterPixelFloor() {
        var brush = BrushSettings.default
        brush.size = 1
        brush.spacing = 0.08
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 100, height: 100))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let append = builder.append(
            .init(x: 1.5, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        #expect(append.points.map(\.x) == [0.75, 1.5])
    }

    @Test func nonfiniteSpacingFallsBackToTheVersionOneDefault() {
        var brush = BrushSettings.default
        brush.size = 100
        brush.spacing = .nan
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 100, height: 100))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let append = builder.append(
            .init(x: 18, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        #expect(append.points.map(\.x) == [18])
    }

    @Test func nonfiniteBrushSizeUsesThePhysicalSpacingFloor() {
        var brush = BrushSettings.default
        brush.size = .infinity
        brush.spacing = 0.60
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 100, height: 100))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let append = builder.append(
            .init(x: 1.5, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        #expect(append.points.map(\.x) == [0.75, 1.5])
    }

    @Test func lowerSpacingCreatesMoreSamplesWithoutExceedingThePointCap() throws {
        var brush = BrushSettings.default
        brush.size = 100
        let maximumPointCount = 32

        brush.spacing = 0.08
        var fine = CanvasStrokeBuilder(
            canvasSize: .init(width: 400, height: 100),
            maximumPointCount: maximumPointCount
        )
        fine.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = fine.append(.init(x: 240, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1))

        brush.spacing = 0.60
        var coarse = CanvasStrokeBuilder(
            canvasSize: .init(width: 400, height: 100),
            maximumPointCount: maximumPointCount
        )
        coarse.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = coarse.append(.init(x: 240, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1))

        let fineCount = try #require(fine.currentStroke).points.count
        let coarseCount = try #require(coarse.currentStroke).points.count
        #expect(fineCount > coarseCount)
        #expect(fineCount <= maximumPointCount)
        #expect(coarseCount <= maximumPointCount)
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

    @Test func equivalentCoarseAndFineCorneredEventsProduceTheSameGeometricStroke() throws {
        var brush = BrushSettings.default
        brush.size = 100
        let start = StrokePoint(x: 0, y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: 0)

        var coarse = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        coarse.begin(layerID: UUID(), tool: .brush, brush: brush, point: start)
        _ = coarse.append(.init(x: 36, y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: 1))
        _ = coarse.append(.init(x: 36, y: 36, pressure: 1, tiltX: 0, tiltY: 0, time: 2))

        var fine = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        fine.begin(layerID: UUID(), tool: .brush, brush: brush, point: start)
        for x in 1...36 {
            _ = fine.append(.init(x: Double(x), y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: Double(x) / 36))
        }
        for y in 1...36 {
            _ = fine.append(.init(x: 36, y: Double(y), pressure: 1, tiltX: 0, tiltY: 0, time: 1 + Double(y) / 36))
        }

        let coarseResult = coarse.finish()
        let fineResult = fine.finish()
        let coarseStroke = try #require(coarseResult)
        let fineStroke = try #require(fineResult)
        #expect(coarseStroke.points.count == fineStroke.points.count)
        #expect(zip(coarseStroke.points, fineStroke.points).allSatisfy { coarsePoint, finePoint in
            coarsePoint.x == finePoint.x && coarsePoint.y == finePoint.y
        })
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

    @Test func configuredPointLimitCarriesATypedDragExhaustionReason() throws {
        var brush = BrushSettings.default
        brush.size = 1
        let maximumPointCount = 4
        var builder = CanvasStrokeBuilder(
            canvasSize: .init(width: 100, height: 100),
            maximumPointCount: maximumPointCount
        )
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )
        let appendResult = builder.append(
            .init(x: 50, y: 50, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        let stroke = try #require(builder.currentStroke)
        #expect(stroke.points.count == maximumPointCount)
        #expect(appendResult.points.count == maximumPointCount - 1)
        #expect(appendResult.isExhausted)
        #expect(
            appendResult.exhaustionReason
                == .pointCapacity(maximumPointCount: maximumPointCount)
        )
        let completion = builder.finish(at: nil)
        #expect(completion.isExhausted)
        #expect(
            completion.exhaustionReason
                == .pointCapacity(maximumPointCount: maximumPointCount)
        )
    }

    @Test func pointerUpExhaustionCarriesTheConfiguredTypedReason() {
        var builder = CanvasStrokeBuilder(
            canvasSize: .init(width: 100, height: 100),
            maximumPointCount: 1
        )
        builder.begin(
            layerID: UUID(),
            tool: .brush,
            brush: .default,
            point: .init(x: 10, y: 10, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let completion = builder.finish(at: .init(
            x: 20, y: 10, pressure: 1, tiltX: 0, tiltY: 0, time: 1
        ))

        // The truncated stroke survives exhaustion so its paint can commit.
        #expect(completion.stroke?.points.count == 1)
        #expect(
            completion.exhaustionReason
                == .pointCapacity(maximumPointCount: 1)
        )
    }

    @Test func exactlyFullStrokeCompletesWithoutExhaustion() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(
            canvasSize: .init(width: 1600, height: 1200),
            maximumPointCount: 3
        )
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 100, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        )

        let append = builder.append(
            .init(x: 36, y: 100, pressure: 1, tiltX: 0, tiltY: 0, time: 2)
        )
        let completion = builder.finish(at: .init(
            x: 36, y: 100, pressure: 1, tiltX: 0, tiltY: 0, time: 3
        ))
        let stroke = try #require(completion.stroke)

        #expect(!append.isExhausted)
        #expect(!completion.isExhausted)
        #expect(stroke.points.map(\.x) == [0, 18, 36])
    }

    @Test func duplicatePointerUpAtFullCapacityUpdatesTheStoredFields() throws {
        var builder = CanvasStrokeBuilder(
            canvasSize: .init(width: 1600, height: 1200),
            maximumPointCount: 1
        )
        builder.begin(
            layerID: UUID(), tool: .brush, brush: .default,
            point: .init(x: 20, y: 30, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        )

        let completion = builder.finish(at: .init(
            x: 20, y: 30, pressure: 1, tiltX: 0.75, tiltY: -0.5, time: 2
        ))
        let stroke = try #require(completion.stroke)

        #expect(!completion.isExhausted)
        #expect(stroke.points == [
            StrokePoint(x: 20, y: 30, pressure: 1, tiltX: 0.75, tiltY: -0.5, time: 2)
        ])
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
        #expect(stroke.points == [
            StrokePoint(x: 200, y: 300, pressure: 1, tiltX: 1, tiltY: -1, time: 1)
        ])
    }

    @Test func zeroMotionInputBecomesTheAnchorForLaterGeometricSampling() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        builder.begin(
            layerID: UUID(), tool: .brush, brush: brush,
            point: .init(x: 0, y: 100, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        )
        _ = builder.append(.init(x: 0, y: 100, pressure: 1, tiltX: 0.5, tiltY: -0.5, time: 1))
        _ = builder.append(.init(x: 18, y: 100, pressure: 1, tiltX: 0.5, tiltY: -0.5, time: 3))

        let completion = builder.finish()
        let stroke = try #require(completion)
        #expect(stroke.points == [
            StrokePoint(x: 0, y: 100, pressure: 0, tiltX: 0, tiltY: 0, time: 0),
            StrokePoint(x: 18, y: 100, pressure: 1, tiltX: 0.5, tiltY: -0.5, time: 3)
        ])
    }
}

@Suite @MainActor struct CanvasEventViewTests {
    @Test func pointerDownSnapshotsCompleteBrushSettingsAcrossPreviewBoundaryForCurrentAndNextStroke() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = PaintLayer(name: "Layer")
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        var submittedBatches: [[StrokePoint]] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    submittedBatches.append(points)
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                }
            )
        )
        let initialBrush = BrushSettings(
            shape: .fan,
            hair: .bristle,
            texture: .salt,
            style: .bloom,
            color: PaintColor(red: 0.18, green: 0.31, blue: 0.52, alpha: 1),
            size: 10,
            opacity: 0.61,
            flow: 0.72,
            water: 0.83,
            granulation: 0.44,
            edgeBloom: 0.91,
            behaviorVersion: 1,
            spacing: 0.08,
            rotation: -37,
            bristleStrength: 0.92,
            textureStrength: 0.81
        )
        let nextBrush = BrushSettings(
            shape: .rigger,
            hair: .synthetic,
            texture: .smooth,
            style: .glazing,
            color: PaintColor(red: 0.58, green: 0.22, blue: 0.11, alpha: 1),
            size: 80,
            opacity: 0.24,
            flow: 0.33,
            water: 0.19,
            granulation: 0.07,
            edgeBloom: 0.12,
            behaviorVersion: 1,
            spacing: 0.60,
            rotation: 124,
            bristleStrength: 0.13,
            textureStrength: 0.26
        )
        model.brush = initialBrush
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 0,
            eventNumber: 0,
            location: CGPoint(x: 20, y: 64)
        )))
        model.brush = nextBrush
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged,
            timestamp: 1,
            eventNumber: 1,
            location: CGPoint(x: 44, y: 64)
        )))
        await model.waitForStrokePreviewIdle()
        #expect(!submittedBatches.isEmpty)
        #expect(submittedBatches.allSatisfy { $0.count <= 8 })
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp,
            timestamp: 2,
            eventNumber: 2,
            location: CGPoint(x: 44, y: 64)
        )))
        await waitForStrokePreviewToFinish(in: model)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 3,
            eventNumber: 3,
            location: CGPoint(x: 92, y: 92)
        )))
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp,
            timestamp: 4,
            eventNumber: 4,
            location: CGPoint(x: 92, y: 92)
        )))
        await waitForStrokePreviewToFinish(in: model)

        let strokes = model.project.commands.compactMap { command -> StrokeCommand? in
            guard case let .stroke(stroke) = command else { return nil }
            return stroke
        }
        #expect(strokes.count == 2)
        #expect(strokes.first?.brush == initialBrush)
        #expect(strokes.first?.points.count ?? 0 > 8)
        #expect(strokes.last?.brush == nextBrush)
    }

    @Test func dragSendsExactlyTheNewInterpolatedPoints() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        var submittedBatches: [[StrokePoint]] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    submittedBatches.append(points)
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                }
            )
        )
        model.brush.size = 100
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 0,
            eventNumber: 0,
            location: CGPoint(x: 64, y: 64)
        )))
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged,
            timestamp: 2,
            eventNumber: 1,
            location: CGPoint(x: 100, y: 64)
        )))
        await model.waitForStrokePreviewIdle()

        #expect(submittedBatches == [[
            StrokePoint(x: 82, y: 192, pressure: 1, tiltX: 0, tiltY: 0, time: 1),
            StrokePoint(x: 100, y: 192, pressure: 1, tiltX: 0, tiltY: 0, time: 2)
        ]])
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
    }

    @Test func longCanvasDragMutatesTheStoredBuilderWithoutRepeatedPrefixCopies() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.brush.size = 1
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)
        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 0,
            eventNumber: 0,
            location: CGPoint(x: 20, y: 64)
        )))
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged,
            timestamp: 1,
            eventNumber: 1,
            location: CGPoint(x: 21, y: 64)
        )))
        let stableStorageIdentity = try #require(view.strokePointStorageIdentityForTesting)

        for index in 2...200 {
            view.mouseDragged(with: try #require(canvasMouseEvent(
                .leftMouseDragged,
                timestamp: Double(index),
                eventNumber: index,
                location: CGPoint(x: 20 + index, y: 64)
            )))
            #expect(view.strokePointStorageIdentityForTesting == stableStorageIdentity)
        }

        await model.waitForStrokePreviewIdle()
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
    }

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

    @Test func strokeBegunWhileFinishingIsRetainedAndPaintsAfterTheRendererFrees() async throws {
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
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
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

        // The quick second stroke is retained while the renderer finishes the
        // first one instead of being dropped.
        #expect(view.hasTransientInputStateForTesting)
        #expect(view.toolTip == "Finishing stroke.")
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp,
            timestamp: 2,
            eventNumber: 2
        )))

        await finish.resume()
        await commit.value
        for _ in 0..<2_000 where model.project.commands.count < 2 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.project.commands.count == 2)
        #expect(model.project.commands.first == .stroke(first))
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 128, y: 128).alpha > 0.05)
    }

    @Test func strokeBegunWhileFinishingStartsItsPreviewOnALaterDrag() async throws {
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
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
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
            .leftMouseDown, timestamp: 1, eventNumber: 1, location: .init(x: 40, y: 128)
        )))
        #expect(!model.isStrokePreviewActive || model.isStrokePreviewFinalizing)

        await finish.resume()
        await commit.value

        // The retained stroke attaches to a live preview on the next drag.
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged, timestamp: 2, eventNumber: 2, location: .init(x: 120, y: 128)
        )))
        #expect(model.isStrokePreviewActive)
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp, timestamp: 3, eventNumber: 3, location: .init(x: 200, y: 128)
        )))
        for _ in 0..<2_000 where model.project.commands.count < 2 {
            await finish.resume()
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.project.commands.count == 2)
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 120, y: 128).alpha > 0.05)
    }

    @Test func offscreenPanIsClampedSoThePaperStaysVisible() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        model.pan = CGSize(width: 100_000, height: -100_000)
        view.synchronize(with: model)

        // synchronize runs inside a SwiftUI view update, where publishing a
        // model change is undefined behavior — the clamp must not fire here.
        #expect(model.pan == CGSize(width: 100_000, height: -100_000))

        // The 256-point paper fills the 256-point view, so panning settles
        // once only the 48-point minimum sliver of paper remains visible.
        for _ in 0..<2_000 where model.pan.width > 208 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.pan == CGSize(width: 208, height: -208))

        model.pan = CGSize(width: 30, height: -12)
        view.synchronize(with: model)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.pan == CGSize(width: 30, height: -12))
    }

    @Test func zeroMotionEventsDoNotScheduleAdditionalPreviewUpdates() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let updates = CanvasPreviewUpdateCounter()
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    await updates.recordUpdate()
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                }
            )
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)
        let down = try #require(canvasMouseEvent(.leftMouseDown, timestamp: 0, eventNumber: 0))
        let duplicate = try #require(canvasMouseEvent(.leftMouseDragged, timestamp: 1, eventNumber: 1))

        view.mouseDown(with: down)
        await model.waitForStrokePreviewIdle()
        view.mouseDragged(with: duplicate)
        await model.waitForStrokePreviewIdle()

        #expect(await updates.count == 0)
    }

    @Test func aggregatePointExhaustionCommitsTheTruncatedPaintAndReportsTheLimit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer")
        let existingStroke = StrokeCommand(
            layerID: layer.id,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 16, y: 16, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(existingStroke)]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(
            project: project,
            renderer: renderer,
            maximumTotalStrokePointCount: 2
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)
        #expect(model.maximumPointCountForNewStroke == 1)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown, timestamp: 1, eventNumber: 1, location: .init(x: 64, y: 64)
        )))
        await model.waitForStrokePreviewIdle()
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged, timestamp: 2, eventNumber: 2, location: .init(x: 200, y: 64)
        )))
        await waitForStrokePreviewToFinish(in: model)

        #expect(!model.isStrokePreviewActive)
        #expect(!view.hasTransientInputStateForTesting)
        #expect(model.project.commands.count == 2)
        #expect(
            model.error?.message
                == "This stroke reached its 1-point limit, so Watercolor Studio ended and saved it there."
        )
        #expect(try renderer.debugPixel(x: 64, y: 192, layerID: layer.id).alpha > 0.05)

        // The document is now at its point capacity, so the next stroke is
        // rejected with the capacity explanation instead of silently failing.
        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown, timestamp: 3, eventNumber: 3, location: .init(x: 96, y: 96)
        )))
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp, timestamp: 4, eventNumber: 4, location: .init(x: 96, y: 96)
        )))
        await waitForStrokePreviewToFinish(in: model)

        #expect(model.project.commands.count == 2)
        #expect(model.error?.message == "The project has reached its point capacity of 2.")
    }

    @Test func exhaustionWithAnInFlightAppendCommitsTheTruncatedStrokeExactlyOnce() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer")]
        )
        let append = CanvasPreviewSuspension()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugPreviewAppendWillCommit: {
                await append.suspend()
            }
        )
        var finishCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(
                        id: id,
                        points: points,
                        token: token
                    )
                },
                finish: { renderer, stroke, token in
                    finishCount += 1
                    try await renderer.finishStrokePreview(stroke, token: token)
                }
            ),
            maximumTotalStrokePointCount: 10
        )
        model.brush.size = 100
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown,
            timestamp: 0,
            eventNumber: 0,
            location: CGPoint(x: 32, y: 64)
        )))
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged,
            timestamp: 1,
            eventNumber: 1,
            location: CGPoint(x: 194, y: 64)
        )))
        await append.waitUntilSuspended()

        // Exhaustion arrives while the first append is still on the GPU. The
        // truncated stroke must wait for that append and then commit once.
        view.mouseDragged(with: try #require(canvasMouseEvent(
            .leftMouseDragged,
            timestamp: 2,
            eventNumber: 2,
            location: CGPoint(x: 220, y: 64)
        )))
        #expect(model.isStrokePreviewActive)

        await append.resume()
        await waitForStrokePreviewToFinish(in: model)

        #expect(finishCount == 1)
        #expect(model.project.commands.count == 1)
        #expect(
            model.error?.message
                == "This stroke reached its 10-point limit, so Watercolor Studio ended and saved it there."
        )
        #expect(!model.isStrokePreviewActive)
        #expect(model.capabilities.canPaint)
    }

    @Test func pointerUpPointExhaustionCommitsTheTruncatedPaintAndReportsTheLimit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer")
        let existingStroke = StrokeCommand(
            layerID: layer.id,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 16, y: 16, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(existingStroke)]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(
            project: project,
            renderer: renderer,
            maximumTotalStrokePointCount: 2
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown, timestamp: 1, eventNumber: 1, location: .init(x: 64, y: 64)
        )))
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp, timestamp: 2, eventNumber: 2, location: .init(x: 128, y: 64)
        )))
        await waitForStrokePreviewToFinish(in: model)

        #expect(model.project.commands.count == 2)
        #expect(
            model.error?.message
                == "This stroke reached its 1-point limit, so Watercolor Studio ended and saved it there."
        )
        #expect(try renderer.debugPixel(x: 64, y: 192, layerID: layer.id).alpha > 0.05)

        view.mouseDown(with: try #require(canvasMouseEvent(
            .leftMouseDown, timestamp: 3, eventNumber: 3, location: .init(x: 96, y: 96)
        )))
        view.mouseUp(with: try #require(canvasMouseEvent(
            .leftMouseUp, timestamp: 4, eventNumber: 4, location: .init(x: 96, y: 96)
        )))
        await waitForStrokePreviewToFinish(in: model)

        #expect(model.project.commands.count == 2)
        #expect(model.error?.message == "The project has reached its point capacity of 2.")
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

private actor CanvasPreviewUpdateCounter {
    private(set) var count = 0

    func recordUpdate() {
        count += 1
    }
}

private actor CanvasPreviewSignal {
    private var hasSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        hasSignalled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !hasSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private func waitForStrokePreviewToFinish(in model: StudioModel) async {
    for _ in 0..<1_000 where model.isStrokePreviewActive {
        await Task.yield()
    }
}

@MainActor
private func canvasChecksum(_ renderer: WatercolorRenderer) throws -> UInt64 {
    let image = try renderer.makeCGImage()
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else {
        throw RendererError.readback("The test could not access image bytes")
    }
    return (0..<CFDataGetLength(data)).reduce(UInt64(0)) { checksum, index in
        (checksum &* 16_777_619) ^ UInt64(bytes[index])
    }
}

@MainActor
private func canvasMouseEvent(
    _ type: NSEvent.EventType,
    timestamp: TimeInterval,
    eventNumber: Int,
    location: CGPoint = CGPoint(x: 128, y: 128)
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: 0,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 1
    )
}
