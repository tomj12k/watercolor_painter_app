import CoreGraphics
import Testing
@testable import WatercolorCore

@Suite struct CanvasTransformTests {
    @Test func clampedPanKeepsAtLeastTheMinimumPaperVisibleOnEachAxis() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )
        // The 1000 × 750 paper sits at x 0, y 25 with zero pan. Panning right
        // is limited so 48 points of paper stay inside the left view edge.
        let farRight = transform.clampedPan(
            .init(width: 5_000, height: 0),
            minimumVisiblePaper: 48
        )
        #expect(farRight.width == 952)
        #expect(farRight.height == 0)

        let farLeft = transform.clampedPan(
            .init(width: -5_000, height: 0),
            minimumVisiblePaper: 48
        )
        #expect(farLeft.width == -952)

        let farDown = transform.clampedPan(
            .init(width: 0, height: 5_000),
            minimumVisiblePaper: 48
        )
        #expect(farDown.height == 727)

        let inRange = transform.clampedPan(
            .init(width: 120, height: -60),
            minimumVisiblePaper: 48
        )
        #expect(inRange == .init(width: 120, height: -60))
    }

    @Test func clampedPanNeverDemandsMoreVisibilityThanThePaperOrViewProvides() {
        // Zoomed far out, the displayed paper is 100 × 75 — smaller than the
        // requested margin — so the whole paper is the visibility requirement.
        let tiny = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 0.1,
            pan: .zero
        )
        let clamped = tiny.clampedPan(
            .init(width: 100_000, height: 100_000),
            minimumVisiblePaper: 48
        )
        let visible = tiny.paperRect
            .offsetBy(dx: clamped.width - tiny.pan.width, dy: clamped.height - tiny.pan.height)
            .intersection(CGRect(origin: .zero, size: tiny.viewSize))
        #expect(visible.width >= 48)
        #expect(visible.height >= 48)

        let degenerate = CanvasTransform(
            viewSize: .zero,
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )
        #expect(degenerate.clampedPan(.init(width: 10, height: 10), minimumVisiblePaper: 48)
            == .init(width: 10, height: 10))
    }

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

    @Test func viewportAnchorsOutsideThePaperAreNotClamped() {
        let transform = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )
        let topLetterboxPoint = CGPoint(x: 500, y: 800)

        #expect(transform.canvasPoint(fromView: topLetterboxPoint) == .init(x: 800, y: 0))
        #expect(transform.viewportPoint(fromView: topLetterboxPoint) == .init(x: 800, y: -40))
    }

    @Test func letterboxViewportAnchorRemainsFixedAcrossZoom() {
        let anchorInView = CGPoint(x: 500, y: 800)
        let before = CanvasTransform(
            viewSize: .init(width: 1000, height: 800),
            canvasSize: .init(width: 1600, height: 1200),
            zoom: 1,
            pan: .zero
        )
        let anchorInCanvas = before.viewportPoint(fromView: anchorInView)
        let provisional = CanvasTransform(
            viewSize: before.viewSize,
            canvasSize: before.canvasSize,
            zoom: 2,
            pan: before.pan
        )
        let shiftedAnchor = provisional.viewPoint(fromCanvas: anchorInCanvas)
        let adjustedPan = CGSize(
            width: before.pan.width + anchorInView.x - shiftedAnchor.x,
            height: before.pan.height + anchorInView.y - shiftedAnchor.y
        )
        let after = CanvasTransform(
            viewSize: before.viewSize,
            canvasSize: before.canvasSize,
            zoom: 2,
            pan: adjustedPan
        )

        #expect(after.viewPoint(fromCanvas: anchorInCanvas) == anchorInView)
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
