import AppKit
import Foundation
import MetalKit
import WatercolorCore

struct StrokeAppendResult: Equatable {
    let points: [StrokePoint]
    let isExhausted: Bool
}

struct StrokeFinishResult {
    let stroke: StrokeCommand?
    let points: [StrokePoint]
    let isExhausted: Bool
}

struct CanvasStrokeBuilder {
    private let canvasSize: CGSize
    private let maximumPointCount: Int
    private var stroke: StrokeCommand?
    private var latestInputPoint: StrokePoint?
    private var distanceToNextSample: Double?
    private var isExhausted = false

    init(
        canvasSize: CGSize,
        maximumPointCount: Int = PaintingProject.maximumStrokePointCount
    ) {
        self.canvasSize = canvasSize
        self.maximumPointCount = max(maximumPointCount, 1)
    }

    var currentStroke: StrokeCommand? { stroke }

    mutating func begin(
        layerID: UUID,
        tool: PaintTool,
        brush: BrushSettings,
        point: StrokePoint
    ) {
        let point = clamped(point)
        stroke = StrokeCommand(
            layerID: layerID,
            tool: tool,
            brush: brush,
            points: [point]
        )
        latestInputPoint = point
        distanceToNextSample = nil
        isExhausted = false
    }

    mutating func append(_ point: StrokePoint) -> StrokeAppendResult {
        guard !isExhausted,
              let stroke,
              let previousInputPoint = latestInputPoint
        else {
            return StrokeAppendResult(points: [], isExhausted: isExhausted)
        }
        let point = clamped(point)
        if samePosition(previousInputPoint, point) {
            latestInputPoint = point
            return StrokeAppendResult(points: [], isExhausted: false)
        }
        let spacing = samplingSpacing(for: stroke.brush)
        let remainingCapacity = maximumPointCount - stroke.points.count
        guard remainingCapacity > 0 else {
            isExhausted = true
            return StrokeAppendResult(points: [], isExhausted: true)
        }

        let sampling = StrokeSampler.sample(
            from: previousInputPoint,
            to: point,
            spacing: spacing,
            distanceToNextSample: distanceToNextSample ?? spacing,
            maximumPointCount: remainingCapacity
        )
        distanceToNextSample = sampling.distanceToNextSample
        latestInputPoint = point
        self.stroke?.points.append(contentsOf: sampling.points)
        isExhausted = sampling.reachedPointLimit
        return StrokeAppendResult(points: sampling.points, isExhausted: isExhausted)
    }

    mutating func finish() -> StrokeCommand? {
        finish(at: nil).stroke
    }

    mutating func finish(at point: StrokePoint?) -> StrokeFinishResult {
        defer {
            stroke = nil
            latestInputPoint = nil
            distanceToNextSample = nil
            isExhausted = false
        }

        var appendedPoints: [StrokePoint] = []
        if let point {
            appendedPoints = append(point).points
        }
        guard !isExhausted, var stroke, let endpoint = latestInputPoint else {
            return StrokeFinishResult(stroke: nil, points: [], isExhausted: true)
        }
        guard let lastStoredPoint = stroke.points.last else {
            return StrokeFinishResult(stroke: nil, points: [], isExhausted: false)
        }
        if samePosition(lastStoredPoint, endpoint) {
            stroke.points[stroke.points.count - 1] = endpoint
        } else {
            guard stroke.points.count < maximumPointCount else {
                return StrokeFinishResult(stroke: nil, points: [], isExhausted: true)
            }
            stroke.points.append(endpoint)
            appendedPoints.append(endpoint)
        }
        return StrokeFinishResult(stroke: stroke, points: appendedPoints, isExhausted: false)
    }

    private func samplingSpacing(for brush: BrushSettings) -> Double {
        let brushSpacing = abs(brush.size) * 0.18
        return brushSpacing.isFinite ? max(brushSpacing, 0.75) : 0.75
    }

    private func samePosition(_ lhs: StrokePoint, _ rhs: StrokePoint) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
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
        updateInputAvailability()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("CanvasEventView must be initialized with a StudioModel")
    }

    public override var acceptsFirstResponder: Bool { true }

    var hasTransientInputStateForTesting: Bool {
        spaceKeyDown || panAnchor != nil || strokeBuilder != nil
    }

    public override func resignFirstResponder() -> Bool {
        resetTransientInputState()
        return super.resignFirstResponder()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    func synchronize(with model: StudioModel) {
        guard self.model !== model else {
            updateInputAvailability()
            requestCanvasDraw()
            return
        }

        self.model.cancelStrokePreview()
        strokeBuilder = nil
        panAnchor = nil
        spaceKeyDown = false
        self.model = model
        model.configureCanvas(self)
        updateInputAvailability()
    }

    public override func resetCursorRects() {
        let cursor: NSCursor = model.capabilities.canPaint ? .crosshair : .operationNotAllowed
        addCursorRect(bounds, cursor: cursor)
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
            completeStroke(with: event)
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
        var builder = CanvasStrokeBuilder(
            canvasSize: CGSize(width: model.project.canvas.width, height: model.project.canvas.height),
            maximumPointCount: max(model.maximumPointCountForNewStroke, 1)
        )
        builder.begin(
            layerID: model.selectedLayerID,
            tool: model.selectedTool,
            brush: model.brush,
            point: strokePoint(from: event)
        )
        guard let stroke = builder.currentStroke,
              model.beginStrokePreview(stroke) == .accepted
        else {
            strokeBuilder = nil
            updateInputAvailability()
            return
        }
        strokeBuilder = builder
    }

    private func appendStrokePoint(from event: NSEvent) {
        guard var builder = strokeBuilder else { return }
        let appendResult = builder.append(strokePoint(from: event))
        strokeBuilder = builder
        guard !appendResult.isExhausted else {
            model.cancelStrokePreview()
            strokeBuilder = nil
            updateInputAvailability()
            return
        }
        guard !appendResult.points.isEmpty else { return }
        if let stroke = builder.currentStroke {
            model.appendStrokePreview(id: stroke.id, points: appendResult.points)
        }
    }

    private func completeStroke(with event: NSEvent) {
        guard var builder = strokeBuilder else { return }
        strokeBuilder = nil
        let completion = builder.finish(at: strokePoint(from: event))
        guard !completion.isExhausted else {
            model.cancelStrokePreview()
            updateInputAvailability()
            return
        }
        guard let stroke = completion.stroke else { return }
        model.appendStrokePreview(id: stroke.id, points: completion.points)
        let model = model
        Task { @MainActor [weak self] in
            await model.commitStrokePreview(stroke)
            self?.requestCanvasDraw()
        }
    }

    private func beginPan(with event: NSEvent) {
        model.cancelStrokePreview()
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

    @objc private func windowDidResignKey() {
        resetTransientInputState()
    }

    private func resetTransientInputState() {
        model.cancelStrokePreview()
        strokeBuilder = nil
        panAnchor = nil
        spaceKeyDown = false
    }

    private func updateInputAvailability() {
        let help: String?
        if model.isStrokePreviewFinalizing {
            help = "Finishing stroke."
        } else if !model.capabilities.canPaint {
            help = "Painting unavailable."
        } else {
            help = nil
        }
        toolTip = help
        setAccessibilityHelp(help)
        window?.invalidateCursorRects(for: self)
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
