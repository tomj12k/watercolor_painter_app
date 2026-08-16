import Foundation
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite(.serialized) @MainActor struct PerformanceQualificationTests {
    private let sampleCount = 30

    @Test func strokePreviewCommitAndGPUQualification() async throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_BENCHMARK"] == "1" else {
            return
        }
        let device = try requiredMetalDevice()

        for layerCount in [1, 8, 12] {
            try await qualifyStrokeLatency(layerCount: layerCount, device: device)
        }
    }

    @Test func structuralEditsAndMainActorHeartbeatQualification() async throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_BENCHMARK"] == "1" else {
            return
        }
        let device = try requiredMetalDevice()
        let project = qualificationProject(layerCount: 8)
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        model.completeStroke(qualificationStroke(
            layerID: project.layers[0].id,
            sample: 0,
            pointCount: 9
        ))
        #expect(model.capabilities.canUndo)

        model.undo()
        model.redo()
        var structuralMilliseconds: [Double] = []
        for sample in 0..<sampleCount {
            let start = ProcessInfo.processInfo.systemUptime
            if sample.isMultiple(of: 2) {
                model.undo()
            } else {
                model.redo()
            }
            structuralMilliseconds.append(
                (ProcessInfo.processInfo.systemUptime - start) * 1_000
            )
        }
        let structuralP50 = percentile(structuralMilliseconds, 0.50)
        let structuralP95 = percentile(structuralMilliseconds, 0.95)
        print(
            "WATERCOLOR_QUALIFICATION metric=structural_history "
                + "samples=\(sampleCount) "
                + "p50_ms=\(format(structuralP50)) "
                + "p95_ms=\(format(structuralP95))"
        )
        #expect(structuralP95 <= 100)

        let undoGap = try await heartbeatGap {
            model.undo()
        }
        let redoGap = try await heartbeatGap {
            model.redo()
        }
        model.selectedLayerID = model.project.layers.last!.id
        let mergeGap = try await heartbeatGap {
            model.mergeSelectedLayerDown()
        }
        let replacement = PaintingProject(
            canvas: CanvasSize(width: 1600, height: 1200),
            paper: .hotPress,
            layers: (1...8).map { PaintLayer(name: "Replacement \($0)") }
        )
        let replacementGap = try await heartbeatGap {
            #expect(model.replaceProjectFromDocument(replacement))
        }
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: exportDirectory) }
        let exportURL = exportDirectory.appendingPathComponent("qualification.png")
        let exportGap = try await heartbeatGap {
            await model.exportPNG(to: exportURL)
        }
        #expect(FileManager.default.fileExists(atPath: exportURL.path))

        let heartbeatResults = [
            ("undo", undoGap),
            ("redo", redoGap),
            ("merge", mergeGap),
            ("document_replacement", replacementGap),
            ("export_readback", exportGap)
        ]
        for (operation, maximumGap) in heartbeatResults {
            print(
                "WATERCOLOR_QUALIFICATION metric=main_actor_heartbeat "
                    + "operation=\(operation) max_gap_ms=\(format(maximumGap))"
            )
            #expect(maximumGap <= 100)
        }
    }

    private func qualifyStrokeLatency(
        layerCount: Int,
        device: MTLDevice
    ) async throws {
        let project = qualificationProject(layerCount: layerCount)
        var latestGPUMilliseconds = 0.0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                let duration = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
                if duration.isFinite, duration >= 0 {
                    latestGPUMilliseconds = duration
                }
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)

        for warmup in 0..<3 {
            _ = try await performStroke(
                sample: warmup,
                model: model,
                layerID: project.layers[0].id,
                latestGPUMilliseconds: &latestGPUMilliseconds
            )
        }

        var previewMilliseconds: [Double] = []
        var commitMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        for sample in 0..<sampleCount {
            let result = try await performStroke(
                sample: sample + 3,
                model: model,
                layerID: project.layers[0].id,
                latestGPUMilliseconds: &latestGPUMilliseconds
            )
            previewMilliseconds.append(result.preview)
            commitMilliseconds.append(result.commit)
            gpuMilliseconds.append(result.gpu)
        }

        let previewP50 = percentile(previewMilliseconds, 0.50)
        let previewP95 = percentile(previewMilliseconds, 0.95)
        let commitP50 = percentile(commitMilliseconds, 0.50)
        let commitP95 = percentile(commitMilliseconds, 0.95)
        let gpuP50 = percentile(gpuMilliseconds, 0.50)
        let gpuP95 = percentile(gpuMilliseconds, 0.95)
        print(
            "WATERCOLOR_QUALIFICATION metric=stroke layers=\(layerCount) "
                + "samples=\(sampleCount) input_hz=120 "
                + "preview_p50_ms=\(format(previewP50)) "
                + "preview_p95_ms=\(format(previewP95)) "
                + "commit_p50_ms=\(format(commitP50)) "
                + "commit_p95_ms=\(format(commitP95)) "
                + "gpu_p50_ms=\(format(gpuP50)) "
                + "gpu_p95_ms=\(format(gpuP95)) "
                + "peak_resource_bytes=\(renderer.estimatedResourceBytes)"
        )
        #expect(previewP95 <= 16.7)
        #expect(commitP95 <= 33.3)
        #expect(gpuP95 > 0)
    }

    private func performStroke(
        sample: Int,
        model: StudioModel,
        layerID: UUID,
        latestGPUMilliseconds: inout Double
    ) async throws -> (preview: Double, commit: Double, gpu: Double) {
        let stroke = qualificationStroke(
            layerID: layerID,
            sample: sample,
            pointCount: 9
        )
        var initial = stroke
        initial.points = [stroke.points[0]]
        guard model.beginStrokePreview(initial) == .accepted else {
            throw PerformanceQualificationError.previewUnavailable
        }

        latestGPUMilliseconds = 0
        let previewStart = ProcessInfo.processInfo.systemUptime
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()
        let preview = (ProcessInfo.processInfo.systemUptime - previewStart) * 1_000
        let previewGPU = latestGPUMilliseconds

        latestGPUMilliseconds = 0
        let commitStart = ProcessInfo.processInfo.systemUptime
        await model.commitStrokePreview(stroke)
        let commit = (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000
        guard model.error == nil, !model.isStrokePreviewActive else {
            throw PerformanceQualificationError.commitFailed
        }
        return (preview, commit, max(previewGPU, latestGPUMilliseconds))
    }

    private func requiredMetalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.metalUnavailable
        }
        return device
    }

    private func qualificationProject(layerCount: Int) -> PaintingProject {
        PaintingProject(
            canvas: CanvasSize(width: 1600, height: 1200),
            paper: .rough,
            layers: (1...layerCount).map { PaintLayer(name: "Layer \($0)") }
        )
    }

    private func qualificationStroke(
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

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func heartbeatGap(
        operation: @escaping @MainActor () async -> Void
    ) async throws -> Double {
        let heartbeat = MainActorHeartbeat()
        heartbeat.start()
        try await Task.sleep(for: .milliseconds(40))
        await operation()
        try await Task.sleep(for: .milliseconds(40))
        return await heartbeat.stop()
    }
}

private enum PerformanceQualificationError: Error {
    case previewUnavailable
    case commitFailed
}

@MainActor
private final class MainActorHeartbeat {
    private var timestamps: [TimeInterval] = []
    private var task: Task<Void, Never>?

    func start() {
        timestamps = [ProcessInfo.processInfo.systemUptime]
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self?.timestamps.append(ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func stop() async -> Double {
        task?.cancel()
        await task?.value
        timestamps.append(ProcessInfo.processInfo.systemUptime)
        task = nil
        return zip(timestamps, timestamps.dropFirst())
            .map { ($1 - $0) * 1_000 }
            .max() ?? 0
    }
}
