import CoreGraphics
import Testing
@testable import WatercolorCore

@Suite struct CanvasTransformTests {
    @Test func viewCenterMapsToCanvasCenterAtFitZoom() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )

        #expect(transform.canvasPoint(fromView: .init(x: 500, y: 400)) == .init(x: 800, y: 600))
    }

    @Test func aspectFitOffsetsPaperAndConvertsToTopLeftCanvasCoordinates() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )

        #expect(transform.paperRect == CGRect(x: 0, y: 25, width: 1000, height: 750))
        #expect(transform.canvasPoint(fromView: .init(x: 0, y: 775)) == .zero)
        #expect(transform.canvasPoint(fromView: .init(x: 1000, y: 25)) == .init(x: 1600, y: 1200))
    }

    @Test func zoomAndPanApplyAroundTheViewCenter() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 2,
            pan: .init(width: 40, height: -30)
        )

        #expect(transform.paperRect == CGRect(x: -460, y: -380, width: 2000, height: 1500))
        #expect(transform.viewPoint(fromCanvas: .init(x: 800, y: 600)) == .init(x: 540, y: 370))
        #expect(transform.canvasPoint(fromView: .init(x: 540, y: 370)) == .init(x: 800, y: 600))
    }

    @Test func pointsOutsideThePaperClampToCanvasEdges() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )

        #expect(transform.canvasPoint(fromView: .init(x: -100, y: 900)) == .zero)
        #expect(transform.canvasPoint(fromView: .init(x: 1100, y: -100)) == .init(x: 1600, y: 1200))
    }

    @Test func normalizedPaperRectUsesTopLeftDisplayCoordinates() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )

        #expect(transform.normalizedPaperRect == CGRect(x: 0, y: 0.03125, width: 1, height: 0.9375))
    }
}
