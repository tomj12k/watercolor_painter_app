import Foundation
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

struct PaperChangeAfterLongStrokesTests {
    @Test @MainActor func changingPaperAfterPaintingLongStrokesStaysResponsive() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer 1")
        let project = PaintingProject(
            canvas: CanvasSize(width: 1_600, height: 1_200),
            paper: .coldPress,
            layers: [layer]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        // Paint a long continuous stroke through the live preview path.
        let points: [StrokePoint] = (0..<240).map { (index: Int) -> StrokePoint in
            let x = 40 + Double(index) * 5.5
            let y = 600 + sin(Double(index) * 0.2) * 120
            return StrokePoint(x: x, y: y, pressure: 0.8, tiltX: 0, tiltY: 0, time: Double(index) / 240)
        }
        let stroke = StrokeCommand(layerID: layer.id, tool: .brush, brush: .default, points: points)
        var initial = stroke
        initial.points = [stroke.points[0]]
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()
        await model.commitStrokePreview(stroke)
        #expect(model.project.commands.count == 1)

        // Changing paper replays the painting, so it must not block the main
        // thread: the call returns immediately with editing paused, and the
        // new surface applies when the replay finishes.
        model.selectPaper(.rough)
        #expect(model.project.paper == .coldPress)
        #expect(!model.capabilities.canPaint)
        #expect(!model.canModifyProject)
        // The pause must be visible: the studio shows why editing is paused
        // while the new surface prepares.
        #expect(model.isApplyingSurfaceChange)

        for _ in 0..<4_000 where model.project.paper != .rough {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.project.paper == .rough)
        #expect(model.capabilities.canPaint)
        #expect(model.canModifyProject)
        #expect(!model.isApplyingSurfaceChange)
        #expect(model.capabilities.canUndo)
        #expect(model.rendererRecoveryError == nil)
        #expect(model.error == nil)

        // The asynchronously applied surface renders exactly what reopening
        // the saved painting would.
        let reopened = try WatercolorRenderer(project: model.project, device: device)
        #expect(
            try model.rendererForTesting.pixelChecksum() == reopened.pixelChecksum()
        )

        // Undo restores the previous surface through the same non-blocking flow.
        model.undo()
        #expect(model.project.paper == .coldPress)
    }
}
