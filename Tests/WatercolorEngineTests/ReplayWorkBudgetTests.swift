import Foundation
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine

/// Replay must stay within the per-submission renderer work budget for any
/// document the live painting path can produce. A customer who painted a
/// large document must never lose undo, open, or recovery to WC-WORK-001:
/// replay splits identical work across additional bounded submissions
/// instead of rejecting the document.
@MainActor
struct ReplayWorkBudgetTests {
    private static func budgetTestCanvas(_ dimension: Int) -> PaintingProject {
        PaintingProject(
            canvas: CanvasSize(width: dimension, height: dimension),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer 1")]
        )
    }

    private static func multiPointStroke(
        layerID: UUID,
        pointCount: Int,
        startTime: Double = 0
    ) -> StrokeCommand {
        StrokeCommand(
            layerID: layerID,
            tool: .brush,
            brush: .default,
            points: (0..<pointCount).map { index in
                StrokePoint(
                    x: 32,
                    y: 32,
                    pressure: 1,
                    tiltX: 0,
                    tiltY: 0,
                    time: startTime + Double(index)
                )
            }
        )
    }

    @Test func replaySplitsOversizedStrokeWorkAcrossBoundedSubmissions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = Self.budgetTestCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 140_000,
                maximumProjectThreads: 200_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        var heavy = original
        heavy.commands = [PaintingCommand.stroke(
            Self.multiPointStroke(layerID: original.layers[0].id, pointCount: 9)
        )]

        try renderer.replay(project: heavy)

        #expect(replaySubmissions > 1)
        #expect(renderer.project == heavy)
        try renderer.renderAndWait(stroke: Self.multiPointStroke(layerID: original.layers[0].id, pointCount: 1, startTime: 1_000))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func replaySplitsHeavyDocumentsAcrossBoundedSubmissions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = Self.budgetTestCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 100_000,
                maximumProjectThreads: 100_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        var heavy = original
        heavy.commands = (0..<12).map { index in
            .stroke(Self.multiPointStroke(
                layerID: original.layers[0].id,
                pointCount: 9,
                startTime: Double(index) * 100
            ))
        }

        try renderer.replay(project: heavy)

        #expect(replaySubmissions > 2)
        #expect(renderer.project == heavy)
    }

    @Test func splitReplayRendersIdenticalPixelsToSingleSubmissionReplay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = Self.budgetTestCanvas(64)
        var heavy = original
        heavy.commands = (0..<4).map { index in
            .stroke(Self.multiPointStroke(
                layerID: original.layers[0].id,
                pointCount: 9,
                startTime: Double(index) * 100
            ))
        }

        let unsplitRenderer = try WatercolorRenderer(project: heavy, device: device)
        var splitSubmissions = 0
        let splitRenderer = try WatercolorRenderer(
            project: heavy,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 100_000,
                maximumProjectThreads: 100_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    splitSubmissions += 1
                }
                return commandBuffer.error
            }
        )

        #expect(splitSubmissions > 1)
        #expect(try splitRenderer.pixelChecksum() == unsplitRenderer.pixelChecksum())
    }

    @Test func oneDispatchBeyondAFreshSubmissionBudgetStillFailsSafely() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = Self.budgetTestCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 6_000,
                maximumProjectThreads: 6_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        let checksumBefore = try renderer.pixelChecksum()
        var hostile = original
        hostile.commands = [
            .stroke(Self.multiPointStroke(layerID: original.layers[0].id, pointCount: 9)),
            .dryLayer(DryLayerCommand(layerID: original.layers[0].id, steps: 100))
        ]

        #expect(throws: RendererError.self) {
            try renderer.replay(project: hostile)
        }

        #expect(replaySubmissions == 0)
        #expect(renderer.project == original)
        #expect(try renderer.pixelChecksum() == checksumBefore)
    }

    @Test func replayLifetimeWorkMayExceedTheProjectBudgetAcrossSubmissions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = Self.budgetTestCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 100_000,
                maximumProjectThreads: 120_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        var heavy = original
        heavy.commands = (0..<12).map { index in
            .stroke(Self.multiPointStroke(
                layerID: original.layers[0].id,
                pointCount: 9,
                startTime: Double(index) * 100
            ))
        }

        // Total replay work here is more than ten times maximumProjectThreads.
        // Budgets bound one submission each, so the replay must still succeed
        // by splitting — a cumulative replay-lifetime cap would make heavy
        // documents impossible to reopen.
        try renderer.replay(project: heavy)

        #expect(replaySubmissions > 2)
        #expect(renderer.project == heavy)
    }

    @Test func productionBudgetAdmitsWorstCaseSingleDispatches() {
        // The irreducible replay dispatch — one simulation step over the
        // largest canvas at full layer depth — must always fit one fresh
        // production submission, so splitting can always make progress.
        let budget = RendererWorkPolicy.live.makeProjectBudget()
        let worstCaseSteps = budget.maximumConsumableSteps(
            regionArea: PaintingProject.maximumCanvasDimension
                * PaintingProject.maximumCanvasDimension,
            sliceDepth: PaintingProject.maximumLayerCount,
            passCount: 2
        )
        #expect(worstCaseSteps >= 1)
    }
}
