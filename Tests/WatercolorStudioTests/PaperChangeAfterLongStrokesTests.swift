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

        // Change the paper surface while the canvas is still wet.
        model.selectPaper(.rough)
        #expect(model.project.paper == .rough)
        model.selectPaper(.handmade)
        #expect(model.project.paper == .handmade)
        #expect(model.rendererRecoveryError == nil)
    }
}
