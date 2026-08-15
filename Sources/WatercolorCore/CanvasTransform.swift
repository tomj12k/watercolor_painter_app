import CoreGraphics

public struct CanvasTransform: Equatable, Sendable {
    public var viewSize: CGSize
    public var canvasSize: CGSize
    public var zoom: CGFloat
    public var pan: CGSize

    public init(viewSize: CGSize, canvasSize: CGSize, zoom: CGFloat, pan: CGSize) {
        self.viewSize = viewSize
        self.canvasSize = canvasSize
        self.zoom = zoom
        self.pan = pan
    }

    public var scale: CGFloat {
        guard viewSize.width > 0,
              viewSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return 0
        }

        let fitScale = min(viewSize.width / canvasSize.width, viewSize.height / canvasSize.height)
        let safeZoom = zoom.isFinite ? max(zoom, 0.01) : 1
        return fitScale * safeZoom
    }

    public var paperRect: CGRect {
        let displayedSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        return CGRect(
            x: (viewSize.width - displayedSize.width) * 0.5 + pan.width,
            y: (viewSize.height - displayedSize.height) * 0.5 + pan.height,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    /// The paper rectangle in top-left-oriented, unit view coordinates for display shaders.
    public var normalizedPaperRect: CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGRect(
            x: paperRect.minX / viewSize.width,
            y: (viewSize.height - paperRect.maxY) / viewSize.height,
            width: paperRect.width / viewSize.width,
            height: paperRect.height / viewSize.height
        )
    }

    public func canvasPoint(fromView point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }

        return CGPoint(
            x: ((point.x - paperRect.minX) / scale).clamped(to: 0...canvasSize.width),
            y: (canvasSize.height - (point.y - paperRect.minY) / scale).clamped(to: 0...canvasSize.height)
        )
    }

    public func viewPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(
            x: paperRect.minX + point.x.clamped(to: 0...canvasSize.width) * scale,
            y: paperRect.minY + (canvasSize.height - point.y.clamped(to: 0...canvasSize.height)) * scale
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
