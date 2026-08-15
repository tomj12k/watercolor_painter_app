import AppKit
import Foundation
import MetalKit
import WatercolorCore

struct CanvasStrokeBuilder {
    private let canvasSize: CGSize
    private var stroke: StrokeCommand?

    init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
    }

    mutating func begin(
        layerID: UUID,
        tool: PaintTool,
        brush: BrushSettings,
        point: StrokePoint
    ) {
        stroke = StrokeCommand(
            layerID: layerID,
            tool: tool,
            brush: brush,
            points: [clamped(point)]
        )
    }

    mutating func append(_ point: StrokePoint) {
        guard var stroke, let previous = stroke.points.last else { return }
        let point = clamped(point)
        guard point != previous else { return }

        let pressureScale = max(point.pressure, 0.12)
        let spacing = abs(stroke.brush.size) * pressureScale * 0.18
        stroke.points.append(contentsOf: StrokeSampler.interpolate(from: previous, to: point, spacing: spacing))
        self.stroke = stroke
    }

    mutating func finish() -> StrokeCommand? {
        defer { stroke = nil }
        return stroke
    }

    private func clamped(_ point: StrokePoint) -> StrokePoint {
        StrokePoint(
            x: point.x.clamped(to: 0...Double(max(canvasSize.width, 0))),
            y: point.y.clamped(to: 0...Double(max(canvasSize.height, 0))),
            pressure: point.pressure.clamped(to: 0...1, fallback: 1),
            tiltX: point.tiltX.clamped(to: -1...1),
            tiltY: point.tiltY.clamped(to: -1...1),
            time: point.time.isFinite ? point.time : 0
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>, fallback: Double = 0) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
public final class CanvasEventView: MTKView {
    private static let minimumZoom: CGFloat = 0.1
    private static let maximumZoom: CGFloat = 16
    private static let spaceKeyCode: CGKeyCode = 49

    private var model: StudioModel
    private var strokeBuilder: CanvasStrokeBuilder?
    private var panAnchor: CGPoint?
    private var spaceKeyDown = false

    public init(model: StudioModel) {
        self.model = model
        super.init(frame: .zero, device: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("CanvasEventView must be initialized with a StudioModel")
    }

    public override var acceptsFirstResponder: Bool { true }

    func synchronize(with model: StudioModel) {
        self.model = model
        requestCanvasDraw()
    }

    public override func keyDown(with event: NSEvent) {
        guard event.keyCode == Self.spaceKeyCode else {
            super.keyDown(with: event)
            return
        }
        spaceKeyDown = true
    }

    public override func keyUp(with event: NSEvent) {
        guard event.keyCode == Self.spaceKeyCode else {
            super.keyUp(with: event)
            return
        }
        spaceKeyDown = false
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isSpacePressed {
            beginPan(with: event)
        } else {
            beginStroke(with: event)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if panAnchor != nil {
            continuePan(with: event)
        } else {
            appendStrokePoint(from: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if panAnchor != nil {
            endPan()
        } else {
            appendStrokePoint(from: event)
            completeStroke()
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        beginPan(with: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, panAnchor != nil else {
            super.otherMouseDragged(with: event)
            return
        }
        continuePan(with: event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, panAnchor != nil else {
            super.otherMouseUp(with: event)
            return
        }
        endPan()
    }

    public override func tabletPoint(with event: NSEvent) {
        guard panAnchor == nil, strokeBuilder != nil else { return }
        appendStrokePoint(from: event)
    }

    public override func magnify(with event: NSEvent) {
        let oldZoom = model.zoom
        let newZoom = (oldZoom * (1 + event.magnification)).clamped(
            to: Self.minimumZoom...Self.maximumZoom
        )
        guard newZoom != oldZoom else { return }

        let location = convert(event.locationInWindow, from: nil)
        let anchoredCanvasPoint = canvasTransform.viewportPoint(fromView: location)
        model.zoom = newZoom
        let shiftedLocation = canvasTransform.viewPoint(fromCanvas: anchoredCanvasPoint)
        model.pan.width += location.x - shiftedLocation.x
        model.pan.height += location.y - shiftedLocation.y
        requestCanvasDraw()
    }

    public override func scrollWheel(with event: NSEvent) {
        model.pan.width += event.scrollingDeltaX
        model.pan.height += event.scrollingDeltaY
        requestCanvasDraw()
    }

    private var canvasTransform: CanvasTransform {
        CanvasTransform(
            viewSize: bounds.size,
            canvasSize: CGSize(width: model.project.canvas.width, height: model.project.canvas.height),
            zoom: model.zoom,
            pan: model.pan
        )
    }

    private var isSpacePressed: Bool {
        spaceKeyDown || CGEventSource.keyState(.combinedSessionState, key: Self.spaceKeyCode)
    }

    private func beginStroke(with event: NSEvent) {
        guard model.capabilities.canPaint else { return }
        var builder = CanvasStrokeBuilder(
            canvasSize: CGSize(width: model.project.canvas.width, height: model.project.canvas.height)
        )
        builder.begin(
            layerID: model.selectedLayerID,
            tool: model.selectedTool,
            brush: model.brush,
            point: strokePoint(from: event)
        )
        strokeBuilder = builder
    }

    private func appendStrokePoint(from event: NSEvent) {
        strokeBuilder?.append(strokePoint(from: event))
    }

    private func completeStroke() {
        guard var builder = strokeBuilder else { return }
        strokeBuilder = nil
        guard let stroke = builder.finish() else { return }
        model.completeStroke(stroke)
        requestCanvasDraw()
    }

    private func beginPan(with event: NSEvent) {
        strokeBuilder = nil
        panAnchor = convert(event.locationInWindow, from: nil)
    }

    private func continuePan(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let panAnchor else { return }
        model.pan.width += location.x - panAnchor.x
        model.pan.height += location.y - panAnchor.y
        self.panAnchor = location
        requestCanvasDraw()
    }

    private func endPan() {
        panAnchor = nil
    }

    private func strokePoint(from event: NSEvent) -> StrokePoint {
        let point = canvasTransform.canvasPoint(fromView: convert(event.locationInWindow, from: nil))
        let tilt = tabletTilt(from: event)
        return StrokePoint(
            x: Double(point.x),
            y: Double(point.y),
            pressure: pressure(from: event),
            tiltX: tilt.x,
            tiltY: tilt.y,
            time: event.timestamp
        )
    }

    private func pressure(from event: NSEvent) -> Double {
        guard Self.pressureEventTypes.contains(event.type) else { return 1 }
        return Double(event.pressure).clamped(to: 0...1, fallback: 1)
    }

    private func tabletTilt(from event: NSEvent) -> (x: Double, y: Double) {
        guard event.type == .tabletPoint || event.subtype == .tabletPoint else { return (0, 0) }
        return (
            Double(event.tilt.x).clamped(to: -1...1),
            Double(event.tilt.y).clamped(to: -1...1)
        )
    }

    private func requestCanvasDraw() {
        model.updateCanvasDisplay(self)
    }

    private static let pressureEventTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        .tabletPoint
    ]
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
