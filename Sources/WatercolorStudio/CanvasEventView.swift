import AppKit
import Foundation
import MetalKit
import WatercolorCore

enum StrokeExhaustionReason: Equatable, Sendable {
    case pointCapacity(maximumPointCount: Int)

    /// Notice for a stroke whose paint was committed up to the limit.
    var message: String {
        switch self {
        case let .pointCapacity(maximumPointCount):
            "This stroke reached its \(maximumPointCount)-point limit, so Watercolor Studio ended and saved it there."
        }
    }

    var recoverySuggestion: String {
        "Start a new stroke to keep painting."
    }

    /// Notice for a stroke whose preview had to be discarded instead of
    /// committed, so it must not claim the paint was saved.
    var cancellationMessage: String {
        switch self {
        case let .pointCapacity(maximumPointCount):
            "This stroke reached its \(maximumPointCount)-point limit and could not be kept."
        }
    }

    var cancellationRecoverySuggestion: String {
        "Use a shorter stroke or a larger brush for wider spacing."
    }
}

struct StrokeAppendResult: Equatable {
    let points: [StrokePoint]
    let exhaustionReason: StrokeExhaustionReason?

    var isExhausted: Bool { exhaustionReason != nil }
}

struct StrokeFinishResult {
    let stroke: StrokeCommand?
    let points: [StrokePoint]
    let exhaustionReason: StrokeExhaustionReason?

    var isExhausted: Bool { exhaustionReason != nil }
}

struct CanvasStrokeBuilder {
    private static let initialPointCapacity = 256

    private let canvasSize: CGSize
    private let maximumPointCount: Int
    private var stroke: StrokeCommand?
    private var latestInputPoint: StrokePoint?
    private var distanceToNextSample: Double?
    private var exhaustionReason: StrokeExhaustionReason?

    init(
        canvasSize: CGSize,
        maximumPointCount: Int = PaintingProject.maximumStrokePointCount
    ) {
        self.canvasSize = canvasSize
        self.maximumPointCount = max(maximumPointCount, 1)
    }

    var currentStroke: StrokeCommand? { stroke }

    var strokeID: UUID? { stroke?.id }

    var pointStorageIdentityForTesting: UInt? {
        stroke?.points.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { UInt(bitPattern: $0) }
        }
    }

    mutating func begin(
        layerID: UUID,
        tool: PaintTool,
        brush: BrushSettings,
        point: StrokePoint
    ) {
        let point = clamped(point)
        var points = [point]
        points.reserveCapacity(min(maximumPointCount, Self.initialPointCapacity))
        stroke = StrokeCommand(
            layerID: layerID,
            tool: tool,
            brush: brush,
            points: points
        )
        latestInputPoint = point
        distanceToNextSample = nil
        exhaustionReason = nil
    }

    mutating func append(_ point: StrokePoint) -> StrokeAppendResult {
        guard exhaustionReason == nil,
              stroke != nil,
              let previousInputPoint = latestInputPoint
        else {
            return StrokeAppendResult(points: [], exhaustionReason: exhaustionReason)
        }
        let point = clamped(point)
        if samePosition(previousInputPoint, point) {
            latestInputPoint = point
            return StrokeAppendResult(points: [], exhaustionReason: nil)
        }
        let spacing = samplingSpacing(for: stroke!.brush)
        let remainingCapacity = maximumPointCount - stroke!.points.count
        guard remainingCapacity > 0 else {
            let reason = StrokeExhaustionReason.pointCapacity(
                maximumPointCount: maximumPointCount
            )
            exhaustionReason = reason
            return StrokeAppendResult(points: [], exhaustionReason: reason)
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
        if sampling.reachedPointLimit {
            exhaustionReason = .pointCapacity(maximumPointCount: maximumPointCount)
        }
        return StrokeAppendResult(
            points: sampling.points,
            exhaustionReason: exhaustionReason
        )
    }

    mutating func finish() -> StrokeCommand? {
        finish(at: nil).stroke
    }

    mutating func finish(at point: StrokePoint?) -> StrokeFinishResult {
        defer {
            stroke = nil
            latestInputPoint = nil
            distanceToNextSample = nil
            exhaustionReason = nil
        }

        var appendedPoints: [StrokePoint] = []
        if let point {
            let appendResult = append(point)
            appendedPoints = appendResult.points
            if let exhaustionReason = appendResult.exhaustionReason {
                // Keep the truncated stroke so its paint can still commit.
                return StrokeFinishResult(
                    stroke: stroke,
                    points: appendedPoints,
                    exhaustionReason: exhaustionReason
                )
            }
        }
        if let exhaustionReason {
            return StrokeFinishResult(
                stroke: stroke,
                points: appendedPoints,
                exhaustionReason: exhaustionReason
            )
        }
        guard stroke != nil, let endpoint = latestInputPoint else {
            return StrokeFinishResult(stroke: nil, points: [], exhaustionReason: nil)
        }
        guard let lastStoredPoint = stroke!.points.last else {
            return StrokeFinishResult(stroke: nil, points: [], exhaustionReason: nil)
        }
        if samePosition(lastStoredPoint, endpoint) {
            stroke!.points[stroke!.points.count - 1] = endpoint
        } else {
            guard stroke!.points.count < maximumPointCount else {
                return StrokeFinishResult(
                    stroke: stroke,
                    points: appendedPoints,
                    exhaustionReason: .pointCapacity(maximumPointCount: maximumPointCount)
                )
            }
            stroke!.points.append(endpoint)
            appendedPoints.append(endpoint)
        }
        return StrokeFinishResult(stroke: stroke, points: appendedPoints, exhaustionReason: nil)
    }

    private func samplingSpacing(for brush: BrushSettings) -> Double {
        guard brush.size.isFinite else { return 0.75 }
        let spacing = brush.spacing.isFinite
            ? min(max(brush.spacing, 0.08), 0.60)
            : 0.18
        return max(abs(brush.size) * spacing, 0.75)
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
    private static let minimumVisiblePaper: CGFloat = 48
    private static let spaceKeyCode: CGKeyCode = 49

    private var model: StudioModel
    private var strokeBuilder: CanvasStrokeBuilder?
    private var strokePreviewStarted = false
    private var deferredStrokeQueue: [(stroke: StrokeCommand, reason: StrokeExhaustionReason?)] = []
    private var deferredStrokeDrainTask: Task<Void, Never>?
    /// How long a deferred stroke may wait for the renderer before it is
    /// dropped and reported. Adjustable so tests need not wait five seconds.
    var deferredStrokeCompletionTimeout: Duration = .seconds(5)
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

    var strokePointStorageIdentityForTesting: UInt? {
        strokeBuilder?.pointStorageIdentityForTesting
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
            // synchronize runs inside a SwiftUI view update, where publishing
            // a model change is undefined behavior. Redraw now; run the pan
            // clamp (which may write model.pan) after the update completes.
            model.updateCanvasDisplay(self)
            scheduleDeferredPanClamp()
            return
        }

        // Cancelling publishes the outgoing model's capabilities, and this
        // path also runs inside a SwiftUI view update — defer it, like the
        // pan clamp above.
        let outgoingModel = self.model
        Task { @MainActor in
            outgoingModel.cancelStrokePreview()
        }
        strokeBuilder = nil
        strokePreviewStarted = false
        deferredStrokeQueue.removeAll()
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
        strokeBuilder = builder
        strokePreviewStarted = false
        startPendingStrokePreviewIfNeeded()
    }

    /// Attaches the accumulating stroke to a live renderer preview. When the
    /// renderer is still finishing the previous stroke, the builder keeps
    /// collecting points and the next input event retries, so quick
    /// successive strokes never silently drop.
    private func startPendingStrokePreviewIfNeeded() {
        // Strokes waiting in the deferred queue were drawn earlier, so a new
        // stroke must not obtain a live preview — and thereby commit — ahead
        // of them. It stays in its builder and joins the queue on pointer up.
        guard deferredStrokeQueue.isEmpty, deferredStrokeDrainTask == nil else { return }
        guard !strokePreviewStarted,
              let stroke = strokeBuilder?.currentStroke,
              let firstPoint = stroke.points.first
        else { return }
        var initial = stroke
        initial.points = [firstPoint]
        switch model.beginStrokePreview(initial) {
        case .accepted:
            strokePreviewStarted = true
            let queuedPoints = Array(stroke.points.dropFirst())
            if !queuedPoints.isEmpty {
                model.appendStrokePreview(id: stroke.id, points: queuedPoints)
            }
        case .busy:
            updateInputAvailability()
        case .unavailable:
            strokeBuilder = nil
            updateInputAvailability()
        }
    }

    private func appendStrokePoint(from event: NSEvent) {
        guard strokeBuilder != nil else { return }
        let appendResult = strokeBuilder!.append(strokePoint(from: event))
        if let exhaustionReason = appendResult.exhaustionReason {
            let truncatedStroke = strokeBuilder?.currentStroke
            let started = strokePreviewStarted
            strokeBuilder = nil
            strokePreviewStarted = false
            if started {
                commitExhaustedStroke(
                    truncatedStroke,
                    newPoints: appendResult.points,
                    reason: exhaustionReason
                )
            } else {
                completeDeferredStroke(truncatedStroke, reason: exhaustionReason)
            }
            return
        }
        guard strokePreviewStarted else {
            startPendingStrokePreviewIfNeeded()
            return
        }
        guard !appendResult.points.isEmpty else { return }
        if let strokeID = strokeBuilder?.strokeID {
            model.appendStrokePreview(id: strokeID, points: appendResult.points)
        }
    }

    private func completeStroke(with event: NSEvent) {
        guard strokeBuilder != nil else { return }
        let started = strokePreviewStarted
        let completion = strokeBuilder!.finish(at: strokePoint(from: event))
        strokeBuilder = nil
        strokePreviewStarted = false
        if let exhaustionReason = completion.exhaustionReason {
            if started {
                commitExhaustedStroke(
                    completion.stroke,
                    newPoints: completion.points,
                    reason: exhaustionReason
                )
            } else {
                completeDeferredStroke(completion.stroke, reason: exhaustionReason)
            }
            return
        }
        guard let stroke = completion.stroke else { return }
        guard started else {
            completeDeferredStroke(stroke, reason: nil)
            return
        }
        model.appendStrokePreview(id: stroke.id, points: completion.points)
        let model = model
        Task { @MainActor [weak self] in
            await model.commitStrokePreview(stroke)
            // The commit belongs to its own model; the view refresh does not
            // once the view has been handed a different model.
            guard let self, self.model === model else { return }
            self.requestCanvasDraw()
        }
    }

    /// Queues a stroke whose preview never obtained the renderer — the
    /// previous stroke was still finishing for its whole, brief lifetime —
    /// so it renders as soon as the renderer frees up. A first-in-first-out
    /// queue keeps deferred strokes in draw order: a later stroke can never
    /// commit ahead of an earlier one that is still waiting.
    private func completeDeferredStroke(
        _ stroke: StrokeCommand?,
        reason: StrokeExhaustionReason?
    ) {
        guard let stroke else { return }
        deferredStrokeQueue.append((stroke: stroke, reason: reason))
        startDeferredStrokeDrainIfNeeded()
    }

    private func startDeferredStrokeDrainIfNeeded() {
        guard deferredStrokeDrainTask == nil, !deferredStrokeQueue.isEmpty else { return }
        let model = model
        deferredStrokeDrainTask = Task { @MainActor [weak self] in
            while let self, self.model === model, !self.deferredStrokeQueue.isEmpty {
                var deadline = ContinuousClock.now.advanced(by: self.deferredStrokeCompletionTimeout)
                while !model.canModifyProject, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(8))
                    // A surface change replays the whole painting on
                    // purpose; its duration says nothing about a stuck
                    // renderer, so the timeout clock restarts after it.
                    if model.isApplyingSurfaceChange {
                        deadline = ContinuousClock.now.advanced(
                            by: self.deferredStrokeCompletionTimeout
                        )
                    }
                }
                guard model.canModifyProject else {
                    // The renderer never freed up; dropping the queue keeps
                    // new painting possible instead of blocking it forever —
                    // and the customer is told the paint could not land.
                    let droppedStrokeCount = self.deferredStrokeQueue.count
                    self.deferredStrokeQueue.removeAll()
                    model.noteDroppedDeferredStrokes(count: droppedStrokeCount)
                    break
                }
                let entry = self.deferredStrokeQueue.removeFirst()
                model.completeStroke(entry.stroke)
                if let reason = entry.reason {
                    model.noteStrokeExhaustion(reason)
                }
            }
            guard let self else { return }
            self.deferredStrokeDrainTask = nil
            self.requestCanvasDraw()
            self.updateInputAvailability()
            self.startDeferredStrokeDrainIfNeeded()
        }
    }

    /// Commits the paint a capacity-ended stroke already produced instead of
    /// discarding it, then surfaces why the stroke ended.
    private func commitExhaustedStroke(
        _ stroke: StrokeCommand?,
        newPoints: [StrokePoint],
        reason: StrokeExhaustionReason
    ) {
        guard let stroke, model.isStrokePreviewActive else {
            model.cancelStrokePreview(reason: reason)
            updateInputAvailability()
            return
        }
        if !newPoints.isEmpty {
            model.appendStrokePreview(id: stroke.id, points: newPoints)
        }
        let model = model
        Task { @MainActor [weak self] in
            await model.commitStrokePreview(stroke)
            model.noteStrokeExhaustion(reason)
            guard let self, self.model === model else { return }
            self.requestCanvasDraw()
            self.updateInputAvailability()
        }
        updateInputAvailability()
    }

    private func beginPan(with event: NSEvent) {
        model.cancelStrokePreview()
        strokeBuilder = nil
        strokePreviewStarted = false
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
        strokePreviewStarted = false
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

    /// Redraws from event-handler paths, where model writes are safe.
    private func requestCanvasDraw() {
        clampPanIfNeeded()
        model.updateCanvasDisplay(self)
    }

    /// Keeps a sliver of paper on screen no matter how far the customer
    /// pans or zooms, so the painting can always be found again.
    private func clampPanIfNeeded() {
        let clampedPan = canvasTransform.clampedPan(
            model.pan,
            minimumVisiblePaper: Self.minimumVisiblePaper
        )
        if clampedPan != model.pan {
            model.pan = clampedPan
        }
    }

    private func scheduleDeferredPanClamp() {
        let model = model
        Task { @MainActor [weak self] in
            guard let self, self.model === model else { return }
            let clampedPan = canvasTransform.clampedPan(
                model.pan,
                minimumVisiblePaper: Self.minimumVisiblePaper
            )
            if clampedPan != model.pan {
                model.pan = clampedPan
                model.updateCanvasDisplay(self)
            }
        }
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
