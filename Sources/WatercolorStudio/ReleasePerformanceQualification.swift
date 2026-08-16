import Foundation
import Metal
import WatercolorCore

enum ReleasePerformanceQualification {
    private static let sampleCount = 30
    private static let inputIntervalMilliseconds = 1_000.0 / 120.0

    @MainActor
    static func run() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw QualificationError.metalUnavailable
        }

        for layerCount in [1, 8, 12] {
            try await qualifyCustomerInput(layerCount: layerCount)
        }
    }

    @MainActor
    private static func qualifyCustomerInput(layerCount: Int) async throws {
        let project = qualificationProject(layerCount: layerCount)
        let model = try StudioModel(project: project)

        for warmup in 0..<3 {
            _ = try await performStroke(
                sample: warmup,
                model: model,
                layerID: project.layers[0].id
            )
        }

        var handlerMilliseconds: [Double] = []
        var cadenceLatenessMilliseconds: [Double] = []
        var backlogMilliseconds: [Double] = []
        var commitMilliseconds: [Double] = []
        for sample in 0..<sampleCount {
            let result = try await performStroke(
                sample: sample + 3,
                model: model,
                layerID: project.layers[0].id
            )
            handlerMilliseconds.append(contentsOf: result.handlers)
            cadenceLatenessMilliseconds.append(contentsOf: result.cadenceLateness)
            backlogMilliseconds.append(result.backlog)
            commitMilliseconds.append(result.commit)
        }

        let handlerP50 = percentile(handlerMilliseconds, 0.50)
        let handlerP95 = percentile(handlerMilliseconds, 0.95)
        let cadenceP95 = percentile(cadenceLatenessMilliseconds, 0.95)
        let backlogP50 = percentile(backlogMilliseconds, 0.50)
        let backlogP95 = percentile(backlogMilliseconds, 0.95)
        let commitP50 = percentile(commitMilliseconds, 0.50)
        let commitP95 = percentile(commitMilliseconds, 0.95)
        print(
            "WATERCOLOR_QUALIFICATION metric=customer_input layers=\(layerCount) "
                + "samples=\(sampleCount) events_per_stroke=8 input_hz=120 "
                + "handler_p50_ms=\(format(handlerP50)) "
                + "handler_p95_ms=\(format(handlerP95)) "
                + "cadence_lateness_p95_ms=\(format(cadenceP95)) "
                + "backlog_p50_ms=\(format(backlogP50)) "
                + "backlog_p95_ms=\(format(backlogP95)) "
                + "commit_p50_ms=\(format(commitP50)) "
                + "commit_p95_ms=\(format(commitP95))"
        )

        try requireThreshold(
            metric: "handler_p95_ms",
            measured: handlerP95,
            allowed: inputIntervalMilliseconds
        )
        try requireThreshold(
            metric: "cadence_lateness_p95_ms",
            measured: cadenceP95,
            allowed: 16.7
        )
        try requireThreshold(
            metric: "backlog_p95_ms",
            measured: backlogP95,
            allowed: 25
        )
        try requireThreshold(
            metric: "commit_p95_ms",
            measured: commitP95,
            allowed: 33.3
        )
    }

    @MainActor
    private static func performStroke(
        sample: Int,
        model: StudioModel,
        layerID: UUID
    ) async throws -> (
        handlers: [Double],
        cadenceLateness: [Double],
        backlog: Double,
        commit: Double
    ) {
        let stroke = qualificationStroke(
            layerID: layerID,
            sample: sample,
            pointCount: 9
        )
        var initial = stroke
        initial.points = [stroke.points[0]]
        guard model.beginStrokePreview(initial) == .accepted else {
            throw QualificationError.previewUnavailable
        }

        let intervalSeconds = inputIntervalMilliseconds / 1_000
        let cadenceStart = ProcessInfo.processInfo.systemUptime
        var handlerMilliseconds: [Double] = []
        var cadenceLatenessMilliseconds: [Double] = []
        var lastSubmission = cadenceStart
        for (eventIndex, point) in stroke.points.dropFirst().enumerated() {
            let target = cadenceStart + Double(eventIndex) * intervalSeconds
            let remaining = target - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                try await Task.sleep(for: .seconds(remaining))
            }
            let submitted = ProcessInfo.processInfo.systemUptime
            cadenceLatenessMilliseconds.append(max((submitted - target) * 1_000, 0))
            let handlerStart = ProcessInfo.processInfo.systemUptime
            model.appendStrokePreview(id: stroke.id, points: [point])
            handlerMilliseconds.append(
                (ProcessInfo.processInfo.systemUptime - handlerStart) * 1_000
            )
            lastSubmission = submitted
        }

        await model.waitForStrokePreviewIdle()
        let backlog = (ProcessInfo.processInfo.systemUptime - lastSubmission) * 1_000
        let commitStart = ProcessInfo.processInfo.systemUptime
        await model.commitStrokePreview(stroke)
        let commit = (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000
        guard model.error == nil, !model.isStrokePreviewActive else {
            throw QualificationError.commitFailed
        }
        return (handlerMilliseconds, cadenceLatenessMilliseconds, backlog, commit)
    }

    private static func qualificationProject(layerCount: Int) -> PaintingProject {
        PaintingProject(
            canvas: CanvasSize(width: 1600, height: 1200),
            paper: .rough,
            layers: (1...layerCount).map { PaintLayer(name: "Layer \($0)") }
        )
    }

    private static func qualificationStroke(
        layerID: UUID,
        sample: Int,
        pointCount: Int
    ) -> StrokeCommand {
        var brush = BrushSettings.default
        brush.size = 12
        brush.spacing = 0.18
        let column = sample % 10
        let row = (sample / 10) % 3
        let startX = 120 + Double(column) * 135
        let startY = 280 + Double(row) * 300
        let points = (0..<pointCount).map { point in
            StrokePoint(
                x: startX + Double(point) * 10,
                y: startY + sin(Double(point) * 0.5) * 16,
                pressure: 0.75,
                tiltX: 0,
                tiltY: 0,
                time: Double(sample) + Double(point) / 120
            )
        }
        return StrokeCommand(
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: points
        )
    }

    private static func requireThreshold(
        metric: String,
        measured: Double,
        allowed: Double
    ) throws {
        guard measured <= allowed else {
            throw QualificationError.thresholdExceeded(
                metric: metric,
                measured: measured,
                allowed: allowed
            )
        }
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private enum QualificationError: Error, CustomStringConvertible {
    case metalUnavailable
    case previewUnavailable
    case commitFailed
    case thresholdExceeded(metric: String, measured: Double, allowed: Double)

    var description: String {
        switch self {
        case .metalUnavailable:
            "A real Metal device is required for release qualification."
        case .previewUnavailable:
            "The customer-input preview could not start."
        case .commitFailed:
            "The customer-input preview could not commit."
        case let .thresholdExceeded(metric, measured, allowed):
            "\(metric) measured \(measured) ms; required at most \(allowed) ms."
        }
    }
}
