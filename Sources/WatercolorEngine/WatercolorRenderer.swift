import CoreGraphics
import Foundation
import Metal
import MetalKit
import WatercolorCore

public enum RendererError: Error, Equatable, Sendable {
    case metalUnavailable
    case shaderCompilation(String)
    case allocation(String)
    case resourceBudgetExceeded(required: Int, available: Int)
    case workBudgetExceeded(required: UInt64, available: UInt64)
    case invalidProject(ProjectValidationError)
    case unknownLayer(UUID)
    case invalidStrokePreview
    case strokePreviewRestoration(String)
    case invalidMetadataChange
    case readback(String)
}

extension RendererError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "Metal is unavailable on this Mac."
        case let .shaderCompilation(message):
            "The watercolor shaders could not be compiled: \(message)"
        case let .allocation(resource):
            "The watercolor renderer could not allocate \(resource)."
        case let .resourceBudgetExceeded(required, available):
            "This canvas needs \(Self.requiredMiB(for: required)) MiB, but Watercolor Studio can safely use \(Self.availableMiB(for: available)) MiB. Reduce the canvas size or layer count."
        case let .workBudgetExceeded(required, available):
            "This painting needs \(required) simulation threads in one rendering budget, but Watercolor Studio safely allows \(available). Reduce the canvas size, stroke count, or drying steps."
        case let .invalidProject(error):
            "The watercolor project is unsafe to render: \(String(describing: error))."
        case let .unknownLayer(identifier):
            "The watercolor renderer does not contain layer \(identifier.uuidString)."
        case .invalidStrokePreview:
            "The live stroke preview is no longer active."
        case let .strokePreviewRestoration(message):
            "The live stroke preview could not restore the painting: \(message)"
        case .invalidMetadataChange:
            "This painting change requires a structural renderer replay."
        case let .readback(message):
            "The rendered image could not be read back: \(message)"
        }
    }

    private static func requiredMiB(for bytes: Int) -> Int {
        let bytesPerMiB = 1_048_576
        let quotient = bytes / bytesPerMiB
        guard bytes % bytesPerMiB != 0 else { return quotient }
        let (roundedUp, didOverflow) = quotient.addingReportingOverflow(1)
        return didOverflow ? .max : roundedUp
    }

    private static func availableMiB(for bytes: Int) -> Int {
        bytes / 1_048_576
    }
}

public struct RendererStrokePreviewToken: Hashable, Sendable {
    fileprivate let id: UUID

    fileprivate init() {
        id = UUID()
    }
}

@MainActor
public final class WatercolorRenderer: NSObject, MTKViewDelegate {
    private static let maximumLayerCapacity = PaintingProject.maximumLayerCount
    private static let simulationStepsPerStroke = 2
    private static let stampBatchSize = 8
    private static let activeRegionLifetimeSteps = 256
    private static let allLayers = UInt32.max

    public private(set) var project: PaintingProject
    public private(set) var viewportSize: CGSize
    public private(set) var canvasWetness: Double

    /// The canvas-sized, top-left-oriented texture consumed by the MTKView display pass.
    public var renderedTexture: MTLTexture { compositeTexture }

    public var estimatedResourceBytes: Int {
        Self.estimatedTextureBytes(
            width: compositeTexture.width,
            height: compositeTexture.height,
            layerCapacity: layerCapacity
        )
            + compositeTexture.width * compositeTexture.height
                * RendererResourcePolicy.previewSnapshotBytesPerPixel
            + layerMetadataBuffer.length
            + wetnessTileMaximumBuffer.length
            + wetnessMaximumBuffer.length
    }

    static func estimatedTextureBytes(width: Int, height: Int, layerCapacity: Int) -> Int {
        guard width > 0, height > 0, layerCapacity > 0 else { return 0 }
        let pixelCount = width * height
        let pingPongLayerBytesPerPixel = 2 * 8 + 2 * 2
        let compositeBytesPerPixel = 2 * 4
        return pixelCount * (layerCapacity * pingPongLayerBytesPerPixel + compositeBytesPerPixel)
    }

    private let device: MTLDevice
    private let resourcePolicy: RendererResourcePolicy
    private let workPolicy: RendererWorkPolicy
    private let projectAdmissionLimits: ProjectAdmissionLimits
    private let commandQueue: MTLCommandQueue
    private let pipelineResources: RendererPipelineResources
    private var stampPipeline: MTLComputePipelineState { pipelineResources.stamp }
    private var simulationPipeline: MTLComputePipelineState { pipelineResources.simulation }
    private var synchronizeRegionPipeline: MTLComputePipelineState { pipelineResources.synchronizeRegion }
    private var smudgePipeline: MTLComputePipelineState { pipelineResources.smudge }
    private var clearPipeline: MTLComputePipelineState { pipelineResources.clear }
    private var copyLayerPipeline: MTLComputePipelineState { pipelineResources.copyLayer }
    private var mergePipeline: MTLComputePipelineState { pipelineResources.merge }
    private var compositePipeline: MTLComputePipelineState { pipelineResources.composite }
    private var wetnessTileMaximumPipeline: MTLComputePipelineState { pipelineResources.wetnessTileMaximum }
    private var wetnessFinalMaximumPipeline: MTLComputePipelineState { pipelineResources.wetnessFinalMaximum }
    private var displayPipeline: MTLRenderPipelineState { pipelineResources.display }
    private let layerMetadataBuffer: MTLBuffer
    private var wetnessTileMaximumBuffer: MTLBuffer
    private let wetnessMaximumBuffer: MTLBuffer

    private var pigmentTextures: [MTLTexture]
    private var wetnessTextures: [MTLTexture]
    private var compositeTexture: MTLTexture
    private var transactionCompositeTexture: MTLTexture
    private let previewPigmentSnapshot: MTLTexture
    private let previewWetnessSnapshot: MTLTexture
    private var frontTextureIndex = 0
    private var layerCapacity: Int
    private var layerSlices: [UUID: Int] = [:]
    private var layerOpacityPreviews: [UUID: Double] = [:]
    private var lastCommandBuffer: MTLCommandBuffer?
    private var lastCommandBufferCompletion: CommandBufferCompletion?
    private let commandBufferErrorProvider: CommandBufferErrorProvider
    #if DEBUG
    private let previewAppendWillCommit: (() async -> Void)?
    private let previewCancellationWillSubmit: (() async -> Void)?
    private let previewFinishWaitEvent: MTLSharedEvent?
    private let previewFinishWaitValue: UInt64
    private let previewFinishDidCommit: ((MTLCommandBuffer) -> Void)?
    private let previewCancellationDidBegin: (() -> Void)?
    #endif
    private var strokePreview: StrokePreviewTransaction?
    private let previewTextureAllocationCount: Int
    private var activeSimulationRegions: [Int: [ActiveSimulationRegion]]
    private var displayZoom: CGFloat = 1
    private var displayPan: CGSize = .zero
    #if DEBUG
    private var replayCount = 0
    private var lastStrokeDispatch = RendererDebugStrokeDispatch.empty
    private var lastPreviewSemanticContextWork = RendererDebugPreviewSemanticContextWork.empty
    private var lastPreviewFinishEncodedPointCount = 0
    private var synchronousPreviewCancellationWaitCount = 0
    private var synchronousPreviewCancellationReplayCount = 0
    private var synchronousReplaySubmissionCount = 0
    #endif

    public convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: { $0.error }
        )
    }

    #if DEBUG
    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugCommandBufferError: @escaping (MTLCommandBuffer) -> Error?
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: debugCommandBufferError
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugResourcePolicy: RendererResourcePolicy
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: debugResourcePolicy,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: { $0.error }
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugWorkPolicy: RendererWorkPolicy
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: debugWorkPolicy,
            performsResourceAdmission: true,
            commandBufferError: { $0.error }
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugWorkPolicy: RendererWorkPolicy,
        debugCommandBufferError: @escaping (MTLCommandBuffer) -> Error?
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: debugWorkPolicy,
            performsResourceAdmission: true,
            commandBufferError: debugCommandBufferError
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugPreviewAppendWillCommit: @escaping () async -> Void
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: { $0.error },
            previewAppendWillCommit: debugPreviewAppendWillCommit
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugPreviewCancellationWillSubmit: @escaping () async -> Void
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: { $0.error },
            previewCancellationWillSubmit: debugPreviewCancellationWillSubmit
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugPreviewFinishWaitEvent: MTLSharedEvent,
        value: UInt64,
        finishDidCommit: @escaping (MTLCommandBuffer) -> Void,
        cancellationDidBegin: @escaping () -> Void
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: { $0.error },
            previewFinishWaitEvent: debugPreviewFinishWaitEvent,
            previewFinishWaitValue: value,
            previewFinishDidCommit: finishDidCommit,
            previewCancellationDidBegin: cancellationDidBegin
        )
    }

    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugProjectAdmissionLimits: ProjectAdmissionLimits,
        debugCommandBufferError: @escaping (MTLCommandBuffer) -> Error?
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            resourcePolicy: nil,
            workPolicy: nil,
            performsResourceAdmission: true,
            commandBufferError: debugCommandBufferError,
            projectAdmissionLimits: debugProjectAdmissionLimits
        )
    }
    #endif

    private init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        pipelineResources sharedPipelineResources: RendererPipelineResources?,
        resourcePolicy requestedResourcePolicy: RendererResourcePolicy?,
        workPolicy requestedWorkPolicy: RendererWorkPolicy?,
        performsResourceAdmission: Bool,
        commandBufferError: @escaping (MTLCommandBuffer) -> Error?,
        previewAppendWillCommit: (() async -> Void)? = nil,
        previewCancellationWillSubmit: (() async -> Void)? = nil,
        previewFinishWaitEvent: MTLSharedEvent? = nil,
        previewFinishWaitValue: UInt64 = 0,
        previewFinishDidCommit: ((MTLCommandBuffer) -> Void)? = nil,
        previewCancellationDidBegin: (() -> Void)? = nil,
        projectAdmissionLimits requestedProjectAdmissionLimits: ProjectAdmissionLimits? = nil
    ) throws {
        let resolvedProjectAdmissionLimits = requestedProjectAdmissionLimits ?? .production
        try Self.validateForRendering(project, limits: resolvedProjectAdmissionLimits)
        let initialReplayPlan = try Self.makeReplayPlan(for: project)
        guard let requestedDevice else {
            throw RendererError.metalUnavailable
        }
        let resolvedResourcePolicy = requestedResourcePolicy ?? .live(device: requestedDevice)
        if performsResourceAdmission {
            try resolvedResourcePolicy.admit(
                width: project.canvas.width,
                height: project.canvas.height,
                layerCapacity: initialReplayPlan.layerCapacity,
                structuralCandidateCapacity: initialReplayPlan.layerCapacity
            )
        }
        guard let commandQueue = requestedDevice.makeCommandQueue() else {
            throw RendererError.allocation("a Metal command queue")
        }

        self.device = requestedDevice
        resourcePolicy = resolvedResourcePolicy
        workPolicy = requestedWorkPolicy ?? .live
        projectAdmissionLimits = resolvedProjectAdmissionLimits
        self.commandQueue = commandQueue
        let resolvedPipelineResources = try sharedPipelineResources
            ?? RendererPipelineResources(device: requestedDevice)
        pipelineResources = resolvedPipelineResources

        guard let layerMetadataBuffer = requestedDevice.makeBuffer(
            length: Self.maximumLayerCapacity * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.allocation("layer metadata")
        }
        self.layerMetadataBuffer = layerMetadataBuffer
        guard let wetnessMaximumBuffer = requestedDevice.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.allocation("a canvas wetness measurement")
        }
        self.wetnessMaximumBuffer = wetnessMaximumBuffer
        wetnessMaximumBuffer.label = "Canvas wetness maximum"
        let wetnessTileCount = Self.wetnessTileCount(
            width: project.canvas.width,
            height: project.canvas.height,
            threadsPerThreadgroup: Self.wetnessTileThreadgroupSize(for: resolvedPipelineResources.wetnessTileMaximum),
            layerCapacity: initialReplayPlan.layerCapacity
        )
        wetnessTileMaximumBuffer = try Self.makeWetnessTileMaximumBuffer(
            device: requestedDevice,
            length: wetnessTileCount * MemoryLayout<UInt32>.stride
        )
        commandBufferErrorProvider = CommandBufferErrorProvider(commandBufferError)
        #if DEBUG
        self.previewAppendWillCommit = previewAppendWillCommit
        self.previewCancellationWillSubmit = previewCancellationWillSubmit
        self.previewFinishWaitEvent = previewFinishWaitEvent
        self.previewFinishWaitValue = previewFinishWaitValue
        self.previewFinishDidCommit = previewFinishDidCommit
        self.previewCancellationDidBegin = previewCancellationDidBegin
        #endif
        strokePreview = nil
        activeSimulationRegions = [:]
        lastCommandBufferCompletion = nil

        let textures = try Self.makeTextures(
            device: requestedDevice,
            width: project.canvas.width,
            height: project.canvas.height,
            layerCapacity: initialReplayPlan.layerCapacity
        )
        pigmentTextures = textures.pigment
        wetnessTextures = textures.wetness
        compositeTexture = textures.composite
        transactionCompositeTexture = textures.transactionComposite
        let previewSnapshot = try Self.makeStrokePreviewSnapshot(
            device: requestedDevice,
            width: project.canvas.width,
            height: project.canvas.height
        )
        previewPigmentSnapshot = previewSnapshot.pigment
        previewWetnessSnapshot = previewSnapshot.wetness
        previewTextureAllocationCount = 2
        layerCapacity = initialReplayPlan.layerCapacity
        self.project = project
        viewportSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        canvasWetness = 0

        super.init()
        try replay(project: project, admittingResources: false)
    }

    public func resizeViewport(_ size: CGSize) {
        viewportSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    public func configureDisplay(zoom: CGFloat, pan: CGSize) {
        displayZoom = zoom
        displayPan = pan
    }

    public func makeCandidate(
        project: PaintingProject,
        retainedCheckpointBytes: Int = 0
    ) throws -> WatercolorRenderer {
        try Self.validateForRendering(project)
        let candidateReplayPlan = try Self.makeReplayPlan(for: project)
        try resourcePolicy.admit(
            width: max(compositeTexture.width, project.canvas.width),
            height: max(compositeTexture.height, project.canvas.height),
            layerCapacity: layerCapacity,
            structuralCandidateCapacity: candidateReplayPlan.layerCapacity,
            retainedCheckpointBytes: retainedCheckpointBytes
        )
        return try WatercolorRenderer(
            project: project,
            device: device,
            pipelineResources: pipelineResources,
            resourcePolicy: resourcePolicy,
            workPolicy: workPolicy,
            performsResourceAdmission: false,
            commandBufferError: commandBufferErrorProvider.operation,
            projectAdmissionLimits: projectAdmissionLimits
        )
    }

    public func render(stroke: StrokeCommand) throws {
        try rejectNontransactionalMutationDuringPreview()
        try render(stroke: stroke, waitUntilCompleted: false)
    }

    public func renderAndWait(stroke: StrokeCommand) throws {
        try rejectNontransactionalMutationDuringPreview()
        try render(stroke: stroke, waitUntilCompleted: true)
    }

    public func recordRenderedStroke(_ stroke: StrokeCommand) throws {
        try rejectNontransactionalMutationDuringPreview()
        project = try prospectiveProject(recording: stroke)
    }

    public func renderAndRecord(stroke: StrokeCommand) throws {
        try rejectNontransactionalMutationDuringPreview()
        let prospectiveProject = try prospectiveProject(recording: stroke)
        try render(stroke: stroke, waitUntilCompleted: true)
        project = prospectiveProject
    }

    public func beginStrokePreview(
        _ stroke: StrokeCommand
    ) throws -> RendererStrokePreviewToken {
        guard strokePreview == nil else {
            throw RendererError.invalidStrokePreview
        }
        do {
            try project.validateForRendering(stroke)
        } catch let error as ProjectValidationError {
            throw RendererError.invalidProject(error)
        }
        guard project.layers.contains(where: { $0.id == stroke.layerID }),
              let layerSlice = layerSlices[stroke.layerID]
        else {
            throw RendererError.unknownLayer(stroke.layerID)
        }
        let token = RendererStrokePreviewToken()
        strokePreview = StrokePreviewTransaction(
            stroke: stroke,
            token: token,
            layerSlice: layerSlice,
            committedSimulationRegions: activeSimulationRegions,
            workBudget: workPolicy.makeProjectBudget()
        )
        return token
    }

    public func appendStrokePreview(
        id: UUID,
        points: [StrokePoint],
        token: RendererStrokePreviewToken
    ) async throws {
        guard let transaction = strokePreview,
              transaction.token == token,
              transaction.strokeID == id,
              transaction.phase == .idle
        else {
            throw RendererError.invalidStrokePreview
        }
        #if DEBUG
        lastPreviewSemanticContextWork = .empty
        #endif
        guard !points.isEmpty else { return }

        let (pointCount, didOverflow) = transaction.absolutePointCount.addingReportingOverflow(
            points.count
        )
        guard !didOverflow, pointCount <= PaintingProject.maximumStrokePointCount else {
            throw RendererError.invalidProject(
                .invalidStrokePointCount(id, didOverflow ? .max : pointCount)
            )
        }
        if let validationError = strokePreviewAppendValidationError(
            id: id,
            points: points,
            startingAt: transaction.absolutePointCount,
            previousTime: transaction.completeStroke.points.last?.time
        ) {
            throw RendererError.invalidProject(validationError)
        }

        var stagedRemainder = transaction.remainder
        stagedRemainder.append(contentsOf: points)
        let canonicalPointCount = max(
            ((stagedRemainder.count - 1) / Self.stampBatchSize) * Self.stampBatchSize,
            0
        )
        guard canonicalPointCount > 0 else {
            transaction.completeStroke.points.append(contentsOf: points)
            transaction.absolutePointCount = pointCount
            transaction.remainder = stagedRemainder
            return
        }

        let canonicalPoints = Array(stagedRemainder.prefix(canonicalPointCount))
        let nextRemainder = Array(stagedRemainder.dropFirst(canonicalPointCount))
        let preparesStampOrientations = Self.preparesStampOrientations(
            for: transaction.strokeTemplate
        )
        #if DEBUG
        var nextBoundaryPointCount = 0
        var predecessorSearchPointCount = 0
        #endif
        let finalSemanticNextPoint: StrokePoint?
        if preparesStampOrientations {
            #if DEBUG
            nextBoundaryPointCount = nextRemainder.first == nil ? 0 : 1
            #endif
            finalSemanticNextPoint = canonicalPoints.last.flatMap { point in
                nextRemainder.first.flatMap {
                    Self.pointsAreCoincident($0, point) ? nil : $0
                }
            }
        } else {
            finalSemanticNextPoint = nil
        }
        let capturesCommittedState = transaction.renderedPointCount == 0
        if capturesCommittedState {
            activeSimulationRegions = transaction.committedSimulationRegions
        }
        var appendedStroke = transaction.strokeTemplate
        appendedStroke.points = canonicalPoints
        transaction.phase = .updating
        do {
            let updatedWorkBudget = try await renderPreview(
                stroke: appendedStroke,
                pointIndexOffset: transaction.renderedPointCount,
                initialPreviousPoint: transaction.lastRenderedPoint,
                initialSemanticPreviousPoint: preparesStampOrientations
                    ? transaction.lastSemanticPreviousPoint
                    : nil,
                finalSemanticNextPoint: finalSemanticNextPoint,
                capturesCommittedState: capturesCommittedState,
                transaction: transaction,
                workBudget: transaction.workBudget
            )
            transaction.stagedWorkBudget = updatedWorkBudget
        } catch {
            if strokePreview === transaction, transaction.phase == .updating {
                transaction.phase = .failed
            }
            throw error
        }
        guard strokePreview === transaction, transaction.phase == .updating else {
            throw RendererError.invalidStrokePreview
        }
        transaction.completeStroke.points.append(contentsOf: points)
        transaction.absolutePointCount = pointCount
        transaction.remainder = nextRemainder
        transaction.renderedPointCount += canonicalPointCount
        if let lastRenderedPoint = canonicalPoints.last {
            if preparesStampOrientations {
                let canonicalPredecessors = canonicalPoints.dropLast().reversed()
                #if DEBUG
                predecessorSearchPointCount += Self.noncoincidentSearchInspectionCount(
                    to: lastRenderedPoint,
                    in: canonicalPredecessors
                )
                #endif
                var semanticPreviousPoint = Self.firstNoncoincidentPoint(
                    to: lastRenderedPoint,
                    in: canonicalPredecessors
                )
                if semanticPreviousPoint == nil {
                    let carriedPredecessors = [
                        transaction.lastRenderedPoint,
                        transaction.lastSemanticPreviousPoint
                    ].compactMap { $0 }
                    #if DEBUG
                    predecessorSearchPointCount += Self.noncoincidentSearchInspectionCount(
                        to: lastRenderedPoint,
                        in: carriedPredecessors
                    )
                    #endif
                    semanticPreviousPoint = Self.firstNoncoincidentPoint(
                        to: lastRenderedPoint,
                        in: carriedPredecessors
                    )
                }
                transaction.lastSemanticPreviousPoint = semanticPreviousPoint
            }
            transaction.lastRenderedPoint = lastRenderedPoint
        }
        #if DEBUG
        lastPreviewSemanticContextWork = RendererDebugPreviewSemanticContextWork(
            nextBoundaryPointCount: nextBoundaryPointCount,
            predecessorSearchPointCount: predecessorSearchPointCount
        )
        #endif
        transaction.commitStagedWorkBudget()
        transaction.phase = .idle
    }

    private func strokePreviewAppendValidationError(
        id: UUID,
        points: [StrokePoint],
        startingAt pointIndexOffset: Int,
        previousTime initialPreviousTime: Double?
    ) -> ProjectValidationError? {
        var previousTime = initialPreviousTime ?? -.infinity
        for (index, point) in points.enumerated() {
            let absoluteIndex = pointIndexOffset + index
            guard point.x.isFinite,
                  point.y.isFinite,
                  point.pressure.isFinite,
                  point.tiltX.isFinite,
                  point.tiltY.isFinite,
                  point.time.isFinite,
                  (0...Double(project.canvas.width)).contains(point.x),
                  (0...Double(project.canvas.height)).contains(point.y),
                  (0...1).contains(point.pressure),
                  (-1...1).contains(point.tiltX),
                  (-1...1).contains(point.tiltY)
            else {
                return .invalidStrokePoint(id, absoluteIndex)
            }
            guard point.time >= previousTime else {
                return .nonMonotonicStrokeTime(id, absoluteIndex)
            }
            previousTime = point.time
        }
        return nil
    }

    public func finishStrokePreview(
        _ stroke: StrokeCommand,
        token: RendererStrokePreviewToken
    ) async throws {
        guard let transaction = strokePreview,
              transaction.token == token,
              transaction.strokeID == stroke.id,
              transaction.layerID == stroke.layerID,
              transaction.phase == .idle,
              transaction.matchesFinalStroke(stroke)
        else {
            throw RendererError.invalidStrokePreview
        }
        transaction.phase = .finishing
        do {
            try await commitStrokePreview(stroke, transaction: transaction)
        } catch {
            let finishError = error
            guard ownsStrokePreview(transaction, phase: .finishing) else {
                throw finishError
            }
            transaction.phase = .failed
            do {
                try await restoreStrokePreviewCancellation(transaction)
            } catch {
                throw RendererError.strokePreviewRestoration(error.localizedDescription)
            }
            throw finishError
        }
    }

    private func commitStrokePreview(
        _ stroke: StrokeCommand,
        transaction: StrokePreviewTransaction
    ) async throws {
        do {
            try project.validateForRendering(stroke)
        } catch let error as ProjectValidationError {
            throw RendererError.invalidProject(error)
        }

        #if DEBUG
        lastPreviewFinishEncodedPointCount = 0
        #endif
        var workBudget = transaction.workBudget
        let previousSimulationState = simulationStateSnapshot
        let commandBuffer = try makeCommandBuffer(label: "Commit watercolor stroke preview")
        #if DEBUG
        if let previewFinishWaitEvent {
            commandBuffer.encodeWaitForEvent(
                previewFinishWaitEvent,
                value: previewFinishWaitValue
            )
        }
        #endif
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a stroke preview completion encoder")
        }
        guard let slice = layerSlices[stroke.layerID] else {
            throw RendererError.unknownLayer(stroke.layerID)
        }
        do {
            var remainder = transaction.strokeTemplate
            remainder.points = transaction.remainder
            if !remainder.points.isEmpty,
               remainder.points.last != stroke.points.last {
                remainder.points[remainder.points.count - 1] = stroke.points[stroke.points.count - 1]
            }
            #if DEBUG
            lastPreviewFinishEncodedPointCount += remainder.points.count
            #endif
            try encodeStrokeAndSimulation(
                stroke: remainder,
                slice: slice,
                pointIndexOffset: transaction.renderedPointCount,
                initialPreviousPoint: transaction.lastRenderedPoint,
                initialSemanticPreviousPoint: transaction.lastSemanticPreviousPoint,
                workBudget: &workBudget,
                with: encoder
            )
        } catch {
            encoder.endEncoding()
            restoreSimulationState(previousSimulationState)
            throw error
        }
        encodeComposite(with: encoder)
        prepareCanvasWetnessMeasurement()
        encodeCanvasWetnessMeasurement(with: encoder)
        encoder.endEncoding()
        if transaction.renderedPointCount == 0
            || activeSimulationRegions.keys.contains(where: { $0 != transaction.layerSlice })
            || transaction.committedSimulationRegions.keys.contains(where: {
                $0 != transaction.layerSlice
            }) {
            transaction.requireReplayOnCancel()
        }
        let provider = commandBufferErrorProvider
        trackCommandBuffer(commandBuffer)
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                transaction.record(provider.error(for: completed))
                continuation.resume()
            }
            commandBuffer.commit()
            #if DEBUG
            previewFinishDidCommit?(commandBuffer)
            #endif
        }
        if lastCommandBuffer === commandBuffer {
            lastCommandBuffer = nil
            lastCommandBufferCompletion = nil
        }
        guard ownsStrokePreview(transaction, phase: .finishing) else {
            throw RendererError.invalidStrokePreview
        }
        if let failure = transaction.failureDescription {
            throw RendererError.allocation("GPU execution: \(failure)")
        }
        readCanvasWetnessMeasurement()
        try resolveStrokePreview(transaction, phase: .finishing)
        _ = transaction.resolveSnapshotCapture()
    }

    public func cancelStrokePreview(_ token: RendererStrokePreviewToken) throws {
        guard let transaction = strokePreview else { return }
        guard transaction.token == token else {
            throw RendererError.invalidStrokePreview
        }
        try cancelStrokePreview(transaction)
    }

    public func restoreStrokePreviewCancellation(
        _ token: RendererStrokePreviewToken
    ) async throws {
        guard let transaction = strokePreview else { return }
        guard transaction.token == token else {
            throw RendererError.invalidStrokePreview
        }
        try await restoreStrokePreviewCancellation(transaction)
    }

    private func restoreStrokePreviewCancellation(
        _ transaction: StrokePreviewTransaction
    ) async throws {
        guard strokePreview === transaction else {
            throw RendererError.invalidStrokePreview
        }
        guard transaction.phase != .cancelling else {
            throw RendererError.invalidStrokePreview
        }
        transaction.phase = .cancelling
        #if DEBUG
        previewCancellationDidBegin?()
        #endif
        activeSimulationRegions = transaction.committedSimulationRegions
        guard let snapshotState = transaction.snapshotStateForCancellation() else {
            try resolveStrokePreview(transaction, phase: .cancelling)
            return
        }
        if transaction.replaysOnCancel {
            do {
                try await replayStrokePreviewCancellation(
                    project: project,
                    transaction: transaction
                )
                try resolveStrokePreview(transaction, phase: .cancelling)
            } catch {
                failStrokePreviewCancellationIfOwned(transaction)
                throw error
            }
            return
        }
        switch snapshotState {
        case .pending:
            try resolveStrokePreview(transaction, phase: .cancelling)
            return
        case .submitted:
            do {
                try await replayStrokePreviewCancellation(
                    project: project,
                    transaction: transaction
                )
                try resolveStrokePreview(transaction, phase: .cancelling)
            } catch {
                failStrokePreviewCancellationIfOwned(transaction)
                throw error
            }
            return
        case .committed:
            break
        }
        do {
            #if DEBUG
            await previewCancellationWillSubmit?()
            #endif
            guard ownsStrokePreview(transaction, phase: .cancelling) else {
                throw RendererError.invalidStrokePreview
            }
            let commandBuffer = try makeCommandBuffer(label: "Cancel watercolor stroke preview")
            try encodeStrokePreviewSnapshotRestore(transaction, with: commandBuffer)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.allocation("a stroke preview cancellation encoder")
            }
            encodeComposite(with: encoder)
            encoder.endEncoding()
            guard ownsStrokePreview(transaction, phase: .cancelling) else {
                throw RendererError.invalidStrokePreview
            }
            try await submitAndWait(commandBuffer)
            try resolveStrokePreview(transaction, phase: .cancelling)
        } catch {
            failStrokePreviewCancellationIfOwned(transaction)
            throw error
        }
    }

    private func ownsStrokePreview(
        _ transaction: StrokePreviewTransaction,
        phase: StrokePreviewPhase
    ) -> Bool {
        strokePreview === transaction && transaction.phase == phase
    }

    private func resolveStrokePreview(
        _ transaction: StrokePreviewTransaction,
        phase: StrokePreviewPhase
    ) throws {
        guard ownsStrokePreview(transaction, phase: phase) else {
            throw RendererError.invalidStrokePreview
        }
        strokePreview = nil
    }

    private func failStrokePreviewCancellationIfOwned(
        _ transaction: StrokePreviewTransaction
    ) {
        guard ownsStrokePreview(transaction, phase: .cancelling) else { return }
        transaction.phase = .failed
    }

    private func cancelStrokePreview(_ transaction: StrokePreviewTransaction) throws {
        guard strokePreview === transaction,
              transaction.phase != .cancelling
        else {
            throw RendererError.invalidStrokePreview
        }
        transaction.phase = .cancelling
        activeSimulationRegions = transaction.committedSimulationRegions
        do {
            guard let snapshotState = transaction.snapshotStateForCancellation() else {
                try resolveStrokePreview(transaction, phase: .cancelling)
                return
            }
            if transaction.replaysOnCancel {
                #if DEBUG
                synchronousPreviewCancellationReplayCount += 1
                #endif
                guard ownsStrokePreview(transaction, phase: .cancelling) else {
                    throw RendererError.invalidStrokePreview
                }
                try replay(project: project, admittingResources: true)
                try resolveStrokePreview(transaction, phase: .cancelling)
                return
            }
            switch snapshotState {
            case .pending:
                try resolveStrokePreview(transaction, phase: .cancelling)
                return
            case .submitted:
                #if DEBUG
                synchronousPreviewCancellationReplayCount += 1
                #endif
                guard ownsStrokePreview(transaction, phase: .cancelling) else {
                    throw RendererError.invalidStrokePreview
                }
                try replay(project: project, admittingResources: true)
                try resolveStrokePreview(transaction, phase: .cancelling)
                return
            case .committed:
                break
            }
            guard ownsStrokePreview(transaction, phase: .cancelling) else {
                throw RendererError.invalidStrokePreview
            }
            let commandBuffer = try makeCommandBuffer(label: "Cancel watercolor stroke preview")
            try encodeStrokePreviewSnapshotRestore(transaction, with: commandBuffer)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.allocation("a stroke preview cancellation encoder")
            }
            encodeComposite(with: encoder)
            encoder.endEncoding()
            guard ownsStrokePreview(transaction, phase: .cancelling) else {
                throw RendererError.invalidStrokePreview
            }
            #if DEBUG
            synchronousPreviewCancellationWaitCount += 1
            #endif
            try submit(commandBuffer, wait: true)
            try resolveStrokePreview(transaction, phase: .cancelling)
        } catch {
            failStrokePreviewCancellationIfOwned(transaction)
            throw error
        }
    }

    private func render(stroke: StrokeCommand, waitUntilCompleted: Bool) throws {
        do {
            try project.validateForRendering(stroke)
        } catch let error as ProjectValidationError {
            throw RendererError.invalidProject(error)
        }
        guard project.layers.contains(where: { $0.id == stroke.layerID }),
              let slice = layerSlices[stroke.layerID]
        else {
            throw RendererError.unknownLayer(stroke.layerID)
        }

        var workBudget = workPolicy.makeProjectBudget()
        let previousSimulationState = simulationStateSnapshot
        let commandBuffer = try makeCommandBuffer(label: "Watercolor stroke")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a stroke command encoder")
        }
        encoder.label = "Watercolor stroke and simulation"
        do {
            try encodeStrokeAndSimulation(
                stroke: stroke,
                slice: slice,
                workBudget: &workBudget,
                with: encoder
            )
        } catch {
            encoder.endEncoding()
            restoreSimulationState(previousSimulationState)
            throw error
        }
        encodeComposite(with: encoder)
        if waitUntilCompleted {
            prepareCanvasWetnessMeasurement()
            encodeCanvasWetnessMeasurement(with: encoder)
        }
        encoder.endEncoding()
        try submit(commandBuffer, wait: waitUntilCompleted)
        if waitUntilCompleted {
            readCanvasWetnessMeasurement()
        }
    }

    private func renderPreview(
        stroke: StrokeCommand,
        pointIndexOffset: Int,
        initialPreviousPoint: StrokePoint?,
        initialSemanticPreviousPoint: StrokePoint?,
        finalSemanticNextPoint: StrokePoint?,
        capturesCommittedState: Bool,
        transaction: StrokePreviewTransaction,
        workBudget initialWorkBudget: RenderWorkBudget
    ) async throws -> RenderWorkBudget {
        guard project.layers.contains(where: { $0.id == stroke.layerID }),
              let slice = layerSlices[stroke.layerID]
        else {
            throw RendererError.unknownLayer(stroke.layerID)
        }

        var workBudget = initialWorkBudget
        let previousSimulationState = simulationStateSnapshot
        let commandBuffer = try makeCommandBuffer(label: "Watercolor stroke preview")
        if capturesCommittedState {
            try encodeStrokePreviewSnapshotCapture(transaction, with: commandBuffer)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a live stroke preview encoder")
        }
        encoder.label = "Live watercolor stroke preview"
        let previewsNonSelectedSlices = activeSimulationRegions.keys.contains {
            $0 != transaction.layerSlice
        }
        do {
            try encodeStrokeAndSimulation(
                stroke: stroke,
                slice: slice,
                pointIndexOffset: pointIndexOffset,
                initialPreviousPoint: initialPreviousPoint,
                initialSemanticPreviousPoint: initialSemanticPreviousPoint,
                finalSemanticNextPoint: finalSemanticNextPoint,
                workBudget: &workBudget,
                with: encoder
            )
        } catch {
            encoder.endEncoding()
            restoreSimulationState(previousSimulationState)
            throw error
        }
        encodeComposite(with: encoder)
        encoder.endEncoding()
        let provider = commandBufferErrorProvider
        trackCommandBuffer(commandBuffer)
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                if capturesCommittedState, completed.status == .completed {
                    transaction.markSnapshotCaptureCompleted()
                }
                transaction.record(provider.error(for: completed))
                continuation.resume()
            }
            if capturesCommittedState {
                transaction.markSnapshotCaptureSubmitted()
            }
            if previewsNonSelectedSlices {
                transaction.requireReplayOnCancel()
            }
            commandBuffer.commit()
        }
        #if DEBUG
        await previewAppendWillCommit?()
        #endif
        if lastCommandBuffer === commandBuffer {
            lastCommandBuffer = nil
            lastCommandBufferCompletion = nil
        }
        if let failure = transaction.failureDescription {
            throw RendererError.allocation("GPU execution: \(failure)")
        }
        return workBudget
    }

    private func encodeStrokePreviewSnapshotCapture(
        _ transaction: StrokePreviewTransaction,
        with commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.allocation("a stroke preview snapshot encoder")
        }
        encodeTextureCopy(
            from: pigmentTextures[frontTextureIndex],
            sourceSlice: transaction.layerSlice,
            to: previewPigmentSnapshot,
            destinationSlice: 0,
            with: encoder
        )
        encodeTextureCopy(
            from: wetnessTextures[frontTextureIndex],
            sourceSlice: transaction.layerSlice,
            to: previewWetnessSnapshot,
            destinationSlice: 0,
            with: encoder
        )
        encoder.endEncoding()
    }

    private func encodeStrokePreviewSnapshotRestore(
        _ transaction: StrokePreviewTransaction,
        with commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.allocation("a stroke preview restore encoder")
        }
        for texture in pigmentTextures {
            encodeTextureCopy(
                from: previewPigmentSnapshot,
                sourceSlice: 0,
                to: texture,
                destinationSlice: transaction.layerSlice,
                with: encoder
            )
        }
        for texture in wetnessTextures {
            encodeTextureCopy(
                from: previewWetnessSnapshot,
                sourceSlice: 0,
                to: texture,
                destinationSlice: transaction.layerSlice,
                with: encoder
            )
        }
        encoder.endEncoding()
    }

    private func encodeTextureCopy(
        from source: MTLTexture,
        sourceSlice: Int,
        to destination: MTLTexture,
        destinationSlice: Int,
        with encoder: MTLBlitCommandEncoder
    ) {
        let size = MTLSize(width: source.width, height: source.height, depth: 1)
        encoder.copy(
            from: source,
            sourceSlice: sourceSlice,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: destination,
            destinationSlice: destinationSlice,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
    }

    public func replay(project newProject: PaintingProject) throws {
        try rejectNontransactionalMutationDuringPreview()
        guard newProject.canvas.width == compositeTexture.width,
              newProject.canvas.height == compositeTexture.height
        else {
            throw RendererError.invalidMetadataChange
        }
        try replay(project: newProject, admittingResources: true)
    }

    public func replayAsynchronously(project newProject: PaintingProject) async throws {
        try rejectNontransactionalMutationDuringPreview()
        guard newProject.canvas.width == compositeTexture.width,
              newProject.canvas.height == compositeTexture.height
        else {
            throw RendererError.invalidMetadataChange
        }
        await Task.yield()
        try await replayAsynchronously(project: newProject, admittingResources: true)
    }

    private func replay(project newProject: PaintingProject, admittingResources: Bool) throws {
        #if DEBUG
        synchronousReplaySubmissionCount += 1
        #endif
        let replayPlan = try admittedReplayPlan(
            for: newProject,
            admittingResources: admittingResources
        )
        try synchronizeGPU(readback: false)
        let commandBuffer = try encodeReplay(project: newProject, plan: replayPlan)
        try submit(commandBuffer, wait: true)
        readCanvasWetnessMeasurement()
    }

    private func replayAsynchronously(
        project newProject: PaintingProject,
        admittingResources: Bool
    ) async throws {
        let replayPlan = try admittedReplayPlan(
            for: newProject,
            admittingResources: admittingResources
        )
        try await synchronizeGPUAsynchronously(readback: false)
        await Task.yield()
        let commandBuffer = try encodeReplay(project: newProject, plan: replayPlan)
        try await submitAndWait(commandBuffer)
        readCanvasWetnessMeasurement()
    }

    private func replayStrokePreviewCancellation(
        project newProject: PaintingProject,
        transaction: StrokePreviewTransaction
    ) async throws {
        let replayPlan = try admittedReplayPlan(
            for: newProject,
            admittingResources: true
        )
        try await synchronizeGPUAsynchronously(readback: false)
        await Task.yield()
        #if DEBUG
        await previewCancellationWillSubmit?()
        #endif
        guard ownsStrokePreview(transaction, phase: .cancelling) else {
            throw RendererError.invalidStrokePreview
        }
        let commandBuffer = try encodeReplay(project: newProject, plan: replayPlan)
        guard ownsStrokePreview(transaction, phase: .cancelling) else {
            throw RendererError.invalidStrokePreview
        }
        try await submitAndWait(commandBuffer)
        readCanvasWetnessMeasurement()
    }

    private func admittedReplayPlan(
        for newProject: PaintingProject,
        admittingResources: Bool
    ) throws -> ReplayPlan {
        try Self.validateForRendering(newProject, limits: projectAdmissionLimits)
        #if DEBUG
        replayCount += 1
        #endif
        let replayPlan = try Self.makeReplayPlan(for: newProject)
        if admittingResources {
            try resourcePolicy.admit(
                width: max(compositeTexture.width, newProject.canvas.width),
                height: max(compositeTexture.height, newProject.canvas.height),
                layerCapacity: layerCapacity,
                structuralCandidateCapacity: replayPlan.layerCapacity
            )
        }
        return replayPlan
    }

    private func encodeReplay(
        project newProject: PaintingProject,
        plan replayPlan: ReplayPlan
    ) throws -> MTLCommandBuffer {
        let replacementTextures: (
            pigment: [MTLTexture],
            wetness: [MTLTexture],
            composite: MTLTexture,
            transactionComposite: MTLTexture
        )?
        if newProject.canvas.width != compositeTexture.width
            || newProject.canvas.height != compositeTexture.height
            || replayPlan.layerCapacity != layerCapacity {
            replacementTextures = try Self.makeTextures(
                device: device,
                width: newProject.canvas.width,
                height: newProject.canvas.height,
                layerCapacity: replayPlan.layerCapacity
            )
        } else {
            replacementTextures = nil
        }
        let replacementWetnessTileMaximumBuffer: MTLBuffer?
        let requiredWetnessTileLength = Self.wetnessTileCount(
            width: newProject.canvas.width,
            height: newProject.canvas.height,
            threadsPerThreadgroup: wetnessTileThreadgroupSize,
            layerCapacity: replayPlan.layerCapacity
        ) * MemoryLayout<UInt32>.stride
        if requiredWetnessTileLength > wetnessTileMaximumBuffer.length {
            replacementWetnessTileMaximumBuffer = try Self.makeWetnessTileMaximumBuffer(
                device: device,
                length: requiredWetnessTileLength
            )
        } else {
            replacementWetnessTileMaximumBuffer = nil
        }

        let commandBuffer = try makeCommandBuffer(label: "Watercolor replay")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a replay command encoder")
        }
        encoder.label = "Deterministic watercolor replay"

        let previousPigmentTextures = pigmentTextures
        let previousWetnessTextures = wetnessTextures
        let previousCompositeTexture = compositeTexture
        let previousTransactionCompositeTexture = transactionCompositeTexture
        let previousWetnessTileMaximumBuffer = wetnessTileMaximumBuffer
        let previousLayerCapacity = layerCapacity
        let previousProject = project
        let previousViewportSize = viewportSize
        let previousLayerSlices = layerSlices
        let previousLayerOpacityPreviews = layerOpacityPreviews
        let previousSimulationState = simulationStateSnapshot
        #if DEBUG
        let previousLastStrokeDispatch = lastStrokeDispatch
        #endif

        do {
            if let replacementTextures {
                pigmentTextures = replacementTextures.pigment
                wetnessTextures = replacementTextures.wetness
                compositeTexture = replacementTextures.composite
                transactionCompositeTexture = replacementTextures.transactionComposite
                layerCapacity = replayPlan.layerCapacity
                viewportSize = CGSize(width: newProject.canvas.width, height: newProject.canvas.height)
            }
            if let replacementWetnessTileMaximumBuffer {
                wetnessTileMaximumBuffer = replacementWetnessTileMaximumBuffer
            }
            project = newProject
            layerSlices = replayPlan.finalLayerSlices
            layerOpacityPreviews.removeAll()
            frontTextureIndex = 0
            activeSimulationRegions = [:]
            updateLayerMetadata()

            encodeClear(targetSlice: Self.allLayers, texturesAt: 0, with: encoder)
            encodeClear(targetSlice: Self.allLayers, texturesAt: 1, with: encoder)

            var workBudget = workPolicy.makeProjectBudget()
            for action in replayPlan.actions {
                workBudget.beginCommand()
                switch action {
                case let .stroke(stroke, slice):
                    try encodeStrokeAndSimulation(
                        stroke: stroke,
                        slice: slice,
                        workBudget: &workBudget,
                        with: encoder
                    )
                case let .simulateDiscardedStroke(pointCount):
                    _ = try encodeActiveSimulation(
                        steps: Self.simulationStepsPerStroke * pointCount,
                        workBudget: &workBudget,
                        with: encoder
                    )
                case let .clear(slice):
                    encodeClear(targetSlice: UInt32(slice), texturesAt: 0, with: encoder)
                    encodeClear(targetSlice: UInt32(slice), texturesAt: 1, with: encoder)
                    activeSimulationRegions.removeValue(forKey: slice)
                case let .duplicate(source, destination):
                    encodeCopy(source: source, destination: destination, with: encoder)
                    activeSimulationRegions[destination] = activeSimulationRegions[source]
                case let .merge(command, source, destination):
                    encodeMerge(command: command, source: source, destination: destination, with: encoder)
                    let mergedRegions = (activeSimulationRegions[destination] ?? [])
                        + (activeSimulationRegions[source] ?? [])
                    activeSimulationRegions[destination] = coalescedActiveRegions(mergedRegions)
                    activeSimulationRegions.removeValue(forKey: source)
                case let .dry(slice, steps):
                    _ = try encodeActiveSimulation(
                        steps: steps,
                        restrictingTo: Set([slice]),
                        workBudget: &workBudget,
                        with: encoder
                    )
                }
            }

            encodeComposite(with: encoder)
            prepareCanvasWetnessMeasurement()
            encodeCanvasWetnessMeasurement(with: encoder)
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            pigmentTextures = previousPigmentTextures
            wetnessTextures = previousWetnessTextures
            compositeTexture = previousCompositeTexture
            transactionCompositeTexture = previousTransactionCompositeTexture
            wetnessTileMaximumBuffer = previousWetnessTileMaximumBuffer
            layerCapacity = previousLayerCapacity
            project = previousProject
            viewportSize = previousViewportSize
            layerSlices = previousLayerSlices
            layerOpacityPreviews = previousLayerOpacityPreviews
            restoreSimulationState(previousSimulationState)
            #if DEBUG
            lastStrokeDispatch = previousLastStrokeDispatch
            #endif
            updateLayerMetadata()
            throw error
        }
        return commandBuffer
    }

    public func applyMetadata(project updatedProject: PaintingProject) throws {
        try rejectNontransactionalMutationDuringPreview()
        let currentIdentifiers = Set(project.layers.map(\.id))
        let updatedIdentifiers = Set(updatedProject.layers.map(\.id))
        guard updatedProject.canvas == project.canvas,
              updatedProject.paper == project.paper,
              updatedProject.commands == project.commands,
              currentIdentifiers == updatedIdentifiers,
              updatedProject.layers.count == project.layers.count
        else {
            throw RendererError.invalidMetadataChange
        }

        try prepareCompositeTransaction(
            project: updatedProject,
            opacityPreviews: [:],
            label: "Apply layer metadata"
        )
        project = updatedProject
        layerOpacityPreviews.removeAll()
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    public func dry(layerID: UUID, steps: Int) throws {
        try rejectNontransactionalMutationDuringPreview()
        guard project.layers.contains(where: { $0.id == layerID }),
              let slice = layerSlices[layerID]
        else {
            throw RendererError.unknownLayer(layerID)
        }

        var workBudget = workPolicy.makeProjectBudget()
        let previousSimulationState = simulationStateSnapshot
        let commandBuffer = try makeCommandBuffer(label: "Dry watercolor layer")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a drying command encoder")
        }
        do {
            _ = try encodeActiveSimulation(
                steps: min(max(0, steps), PaintingProject.maximumDryStepCount),
                restrictingTo: Set([slice]),
                workBudget: &workBudget,
                with: encoder
            )
        } catch {
            encoder.endEncoding()
            restoreSimulationState(previousSimulationState)
            throw error
        }
        encodeComposite(with: encoder)
        prepareCanvasWetnessMeasurement()
        encodeCanvasWetnessMeasurement(with: encoder)
        encoder.endEncoding()
        try submit(commandBuffer, wait: true)
        readCanvasWetnessMeasurement()
    }

    public func previewLayerOpacity(id: UUID, opacity: Double) throws {
        try rejectNontransactionalMutationDuringPreview()
        guard project.layers.contains(where: { $0.id == id }) else {
            throw RendererError.unknownLayer(id)
        }
        guard opacity.isFinite else { return }
        var candidatePreviews = layerOpacityPreviews
        candidatePreviews[id] = min(max(opacity, 0), 1)
        try prepareCompositeTransaction(
            project: project,
            opacityPreviews: candidatePreviews,
            label: "Preview layer metadata"
        )
        layerOpacityPreviews = candidatePreviews
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    public func clearLayerOpacityPreview(id: UUID) throws {
        try rejectNontransactionalMutationDuringPreview()
        guard project.layers.contains(where: { $0.id == id }) else {
            throw RendererError.unknownLayer(id)
        }
        guard layerOpacityPreviews[id] != nil else { return }
        var candidatePreviews = layerOpacityPreviews
        candidatePreviews.removeValue(forKey: id)
        try prepareCompositeTransaction(
            project: project,
            opacityPreviews: candidatePreviews,
            label: "Preview layer metadata"
        )
        layerOpacityPreviews = candidatePreviews
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    private func rejectNontransactionalMutationDuringPreview() throws {
        guard strokePreview == nil else {
            throw RendererError.invalidStrokePreview
        }
    }

    public func draw(in view: MTKView) {
        guard view.colorPixelFormat == .bgra8Unorm,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        commandBuffer.label = "Display watercolor composite"
        encoder.label = "Watercolor display pass"
        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(compositeTexture, index: 0)
        let paperRect = CanvasTransform(
            viewSize: view.bounds.size,
            canvasSize: CGSize(width: compositeTexture.width, height: compositeTexture.height),
            zoom: displayZoom,
            pan: displayPan
        ).normalizedPaperRect
        var displayParameters = SIMD4<Float>(
            Float(paperRect.minX),
            Float(paperRect.minY),
            Float(paperRect.width),
            Float(paperRect.height)
        )
        encoder.setFragmentBytes(
            &displayParameters,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        trackCommandBuffer(commandBuffer)
        commandBuffer.commit()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resizeViewport(size)
    }

    public func makeCGImage() throws -> CGImage {
        try synchronizeGPU(readback: true)
        let width = compositeTexture.width
        let height = compositeTexture.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            compositeTexture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw RendererError.readback("Core Graphics rejected the pixel data provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw RendererError.readback("Core Graphics could not create the image")
        }
        return image
    }

    private static func relevantLayerIDs(in project: PaintingProject) throws -> Set<UUID> {
        guard !project.layers.isEmpty, project.layers.count <= Self.maximumLayerCapacity else {
            throw RendererError.allocation("metadata for \(project.layers.count) layers")
        }
        let currentIdentifiers = project.layers.map(\.id)
        guard Set(currentIdentifiers).count == currentIdentifiers.count else {
            throw RendererError.allocation("metadata for duplicate layer identifiers")
        }

        var relevant = Set(currentIdentifiers)
        for command in project.commands.reversed() {
            switch command {
            case let .duplicateLayer(duplicate) where relevant.contains(duplicate.destinationLayerID):
                relevant.insert(duplicate.sourceLayerID)
            case let .mergeDown(merge) where relevant.contains(merge.destinationLayerID):
                relevant.insert(merge.sourceLayerID)
            default:
                break
            }
        }
        return relevant
    }

    private static func validateForRendering(
        _ project: PaintingProject,
        limits: ProjectAdmissionLimits = .production
    ) throws {
        do {
            try project.validateForRendering(limits: limits)
        } catch let error as ProjectValidationError {
            throw RendererError.invalidProject(error)
        }
    }

    private func prospectiveProject(recording stroke: StrokeCommand) throws -> PaintingProject {
        guard project.layers.contains(where: { $0.id == stroke.layerID }) else {
            throw RendererError.unknownLayer(stroke.layerID)
        }
        do {
            try project.validateForRendering(
                adding: stroke,
                limits: projectAdmissionLimits
            )
        } catch let error as ProjectValidationError {
            throw RendererError.invalidProject(error)
        }
        var prospectiveProject = project
        prospectiveProject.commands.append(.stroke(stroke))
        return prospectiveProject
    }

    private static func makeReplayPlan(for project: PaintingProject) throws -> ReplayPlan {
        let relevantLayerIDs = try relevantLayerIDs(in: project)
        let currentLayerIDs = Set(project.layers.map(\.id))
        let releasesByCommand = historicalLayerReleases(
            in: project,
            relevantLayerIDs: relevantLayerIDs,
            currentLayerIDs: currentLayerIDs
        )
        var layerSlices: [UUID: Int] = [:]
        var freeSlices = Array((0..<maximumLayerCapacity).reversed())
        var actions: [ReplayAction] = []
        var peakLayerCount = 0

        for (commandIndex, command) in project.commands.enumerated() {
            switch command {
            case let .stroke(stroke):
                if relevantLayerIDs.contains(stroke.layerID) {
                    let slice = try acquireReplaySlice(
                        for: stroke.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.stroke(stroke, slice))
                } else {
                    actions.append(.simulateDiscardedStroke(stroke.points.count))
                }
            case let .clearLayer(clear):
                if relevantLayerIDs.contains(clear.layerID) {
                    let slice = try acquireReplaySlice(
                        for: clear.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.clear(slice))
                }
            case let .duplicateLayer(duplicate):
                if relevantLayerIDs.contains(duplicate.destinationLayerID) {
                    let source = try acquireReplaySlice(
                        for: duplicate.sourceLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    let destination = try acquireReplaySlice(
                        for: duplicate.destinationLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.duplicate(source, destination))
                }
            case let .mergeDown(merge):
                if relevantLayerIDs.contains(merge.destinationLayerID) {
                    let source = try acquireReplaySlice(
                        for: merge.sourceLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    let destination = try acquireReplaySlice(
                        for: merge.destinationLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.merge(merge, source, destination))
                }
            case let .dryLayer(dry):
                if relevantLayerIDs.contains(dry.layerID) {
                    let slice = try acquireReplaySlice(
                        for: dry.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.dry(slice, dry.steps))
                }
            }
            peakLayerCount = max(peakLayerCount, layerSlices.count)
            for layerID in releasesByCommand[commandIndex, default: []] {
                if let slice = layerSlices.removeValue(forKey: layerID) {
                    actions.append(.clear(slice))
                    freeSlices.append(slice)
                }
            }
        }
        for layer in project.layers {
            _ = try acquireReplaySlice(
                for: layer.id,
                layerSlices: &layerSlices,
                freeSlices: &freeSlices
            )
            peakLayerCount = max(peakLayerCount, layerSlices.count)
        }
        return ReplayPlan(
            actions: actions,
            finalLayerSlices: layerSlices,
            layerCapacity: max(peakLayerCount, 1)
        )
    }

    private static func historicalLayerReleases(
        in project: PaintingProject,
        relevantLayerIDs: Set<UUID>,
        currentLayerIDs: Set<UUID>
    ) -> [Int: [UUID]] {
        var lastUse: [UUID: Int] = [:]
        for (index, command) in project.commands.enumerated() {
            let usedLayerIDs: [UUID]
            switch command {
            case let .stroke(stroke) where relevantLayerIDs.contains(stroke.layerID):
                usedLayerIDs = [stroke.layerID]
            case let .clearLayer(clear) where relevantLayerIDs.contains(clear.layerID):
                usedLayerIDs = [clear.layerID]
            case let .duplicateLayer(duplicate) where relevantLayerIDs.contains(duplicate.destinationLayerID):
                usedLayerIDs = [duplicate.sourceLayerID, duplicate.destinationLayerID]
            case let .mergeDown(merge) where relevantLayerIDs.contains(merge.destinationLayerID):
                usedLayerIDs = [merge.sourceLayerID, merge.destinationLayerID]
            case let .dryLayer(dry) where relevantLayerIDs.contains(dry.layerID):
                usedLayerIDs = [dry.layerID]
            default:
                usedLayerIDs = []
            }
            for layerID in usedLayerIDs where !currentLayerIDs.contains(layerID) {
                lastUse[layerID] = index
            }
        }
        return Dictionary(grouping: lastUse, by: \.value)
            .mapValues { $0.map(\.key) }
    }

    private static func acquireReplaySlice(
        for layerID: UUID,
        layerSlices: inout [UUID: Int],
        freeSlices: inout [Int]
    ) throws -> Int {
        if let existing = layerSlices[layerID] {
            return existing
        }
        guard let slice = freeSlices.popLast() else {
            throw RendererError.allocation("12 pigment slices for simultaneously active layers")
        }
        layerSlices[layerID] = slice
        return slice
    }

    private func updateLayerMetadata(
        project metadataProject: PaintingProject? = nil,
        opacityPreviews: [UUID: Double]? = nil
    ) {
        let metadataProject = metadataProject ?? project
        let opacityPreviews = opacityPreviews ?? layerOpacityPreviews
        let pointer = layerMetadataBuffer.contents().bindMemory(
            to: SIMD4<Float>.self,
            capacity: Self.maximumLayerCapacity
        )
        for index in 0..<Self.maximumLayerCapacity {
            pointer[index] = .zero
        }
        for (index, layer) in metadataProject.layers.enumerated() {
            guard let slice = layerSlices[layer.id] else { continue }
            pointer[index] = SIMD4(
                Float(slice),
                Float(min(max(opacityPreviews[layer.id] ?? layer.opacity, 0), 1)),
                layer.isVisible ? 1 : 0,
                0
            )
        }
    }

    private func encodeStrokeAndSimulation(
        stroke: StrokeCommand,
        slice: Int,
        pointIndexOffset: Int = 0,
        initialPreviousPoint: StrokePoint? = nil,
        initialSemanticPreviousPoint: StrokePoint? = nil,
        finalSemanticNextPoint: StrokePoint? = nil,
        restrictingSimulationTo restrictedSimulationSlices: Set<Int>? = nil,
        workBudget: inout RenderWorkBudget,
        with encoder: MTLComputeCommandEncoder
    ) throws {
        guard !stroke.points.isEmpty else { return }
        var stampBatchCount = 0
        var simulationStepCount = 0
        var simulationThreadCount = 0
        var largestDispatchedRegion: CanvasRegion?
        var simulatedSlices = Set<Int>()
        let preparesStampOrientations = Self.preparesStampOrientations(for: stroke)
        var semanticPreviousPoint = preparesStampOrientations
            ? initialSemanticPreviousPoint
            : nil
        #if DEBUG
        var orientationPreparationPointCount = 0
        #endif

        // Resolve coincident runs inside the same fixed batches used by live
        // preview. Fresh replay must not see farther into the future than a
        // preview delta did, or a later curve would change an earlier stamp.
        for batchStart in stride(from: 0, to: stroke.points.count, by: Self.stampBatchSize) {
            let batchEnd = min(batchStart + Self.stampBatchSize, stroke.points.count)
            var batch = stroke
            batch.points = Array(stroke.points[batchStart..<batchEnd])
            let immediatePreviousPoint = batchStart > 0
                ? stroke.points[batchStart - 1]
                : initialPreviousPoint
            let orientations: [SIMD4<Float>]?
            if preparesStampOrientations {
                let immediateNextPoint = batchEnd < stroke.points.count
                    ? stroke.points[batchEnd]
                    : finalSemanticNextPoint
                let semanticNextPoint = batch.points.last.flatMap { point in
                    immediateNextPoint.flatMap {
                        Self.pointsAreCoincident($0, point) ? nil : $0
                    }
                }
                #if DEBUG
                orientationPreparationPointCount += batch.points.count
                #endif
                orientations = Self.stampOrientations(
                    for: batch.points,
                    initialPreviousPoint: immediatePreviousPoint,
                    initialSemanticPreviousPoint: semanticPreviousPoint,
                    finalSemanticNextPoint: semanticNextPoint,
                    brush: stroke.brush
                )
            } else {
                orientations = nil
            }
            encode(
                stroke: batch,
                slice: slice,
                pointIndexOffset: pointIndexOffset + batchStart,
                previousPoint: immediatePreviousPoint,
                orientations: orientations,
                with: encoder
            )
            if preparesStampOrientations, let lastPoint = batch.points.last {
                semanticPreviousPoint = Self.firstNoncoincidentPoint(
                    to: lastPoint,
                    in: batch.points.dropLast().reversed()
                ) ?? Self.firstNoncoincidentPoint(
                    to: lastPoint,
                    in: [immediatePreviousPoint, semanticPreviousPoint].compactMap { $0 }
                )
            }

            guard let stampRegion = CanvasRegion.forStroke(batch, canvas: project.canvas) else { continue }
            let stepCount = Self.simulationStepsPerStroke * batch.points.count
            registerActiveSimulationRegion(stampRegion, slice: slice)
            let dispatches = try encodeActiveSimulation(
                steps: stepCount,
                restrictingTo: restrictedSimulationSlices,
                workBudget: &workBudget,
                with: encoder
            )
            stampBatchCount += 1
            simulationStepCount += stepCount
            for dispatch in dispatches {
                simulatedSlices.insert(dispatch.slice)
                simulationThreadCount += dispatch.region.area * dispatch.steps * dispatch.gridDepth
                if largestDispatchedRegion == nil
                    || dispatch.region.area > largestDispatchedRegion!.area {
                    largestDispatchedRegion = dispatch.region
                }
            }
        }

        #if DEBUG
        lastStrokeDispatch = RendererDebugStrokeDispatch(
            stampBatchCount: stampBatchCount,
            simulationStepCount: simulationStepCount,
            activeSliceDepth: simulatedSlices.count,
            simulationRegion: largestDispatchedRegion?.cgRect ?? .zero,
            simulationThreadCount: simulationThreadCount,
            orientationPreparationPointCount: orientationPreparationPointCount
        )
        #endif
    }

    private func registerActiveSimulationRegion(_ region: CanvasRegion, slice: Int) {
        let newRegion = ActiveSimulationRegion(
            region: region.padded(by: 2, canvas: project.canvas),
            remainingSteps: Self.activeRegionLifetimeSteps
        )
        activeSimulationRegions[slice] = coalescedActiveRegions(
            (activeSimulationRegions[slice] ?? []) + [newRegion]
        )
    }

    private var simulationStateSnapshot: SimulationStateSnapshot {
        SimulationStateSnapshot(
            frontTextureIndex: frontTextureIndex,
            activeSimulationRegions: activeSimulationRegions
        )
    }

    private func restoreSimulationState(_ snapshot: SimulationStateSnapshot) {
        frontTextureIndex = snapshot.frontTextureIndex
        activeSimulationRegions = snapshot.activeSimulationRegions
    }

    @discardableResult
    private func encodeActiveSimulation(
        steps: Int,
        restrictingTo restrictedSlices: Set<Int>? = nil,
        workBudget: inout RenderWorkBudget,
        with encoder: MTLComputeCommandEncoder
    ) throws -> [SimulationDispatch] {
        guard steps > 0 else { return [] }
        let slices = activeSimulationRegions.keys
            .filter { restrictedSlices?.contains($0) ?? true }
            .sorted()
        var dispatches: [SimulationDispatch] = []

        for slice in slices {
            let regions = coalescedActiveRegions(activeSimulationRegions[slice] ?? [])
            var advancedRegions: [ActiveSimulationRegion] = []
            for activeRegion in regions {
                let simulationRegion = activeRegion.region.padded(by: steps, canvas: project.canvas)
                try encodeSimulation(
                    steps: steps,
                    targetSlice: UInt32(slice),
                    region: simulationRegion,
                    workBudget: &workBudget,
                    with: encoder
                )
                dispatches.append(SimulationDispatch(
                    slice: slice,
                    region: simulationRegion,
                    steps: steps,
                    gridDepth: 1
                ))
                let remainingSteps = activeRegion.remainingSteps - steps
                if remainingSteps > 0 {
                    advancedRegions.append(ActiveSimulationRegion(
                        region: simulationRegion,
                        remainingSteps: remainingSteps
                    ))
                }
            }
            let coalesced = coalescedActiveRegions(advancedRegions)
            if coalesced.isEmpty {
                activeSimulationRegions.removeValue(forKey: slice)
            } else {
                activeSimulationRegions[slice] = coalesced
            }
        }
        return dispatches
    }

    private func coalescedActiveRegions(
        _ regions: [ActiveSimulationRegion]
    ) -> [ActiveSimulationRegion] {
        var result: [ActiveSimulationRegion] = []
        for candidate in regions {
            var merged = candidate
            var index = result.count - 1
            while index >= 0 {
                guard merged.region.intersectsOrTouches(result[index].region) else {
                    index -= 1
                    continue
                }
                let existing = result.remove(at: index)
                merged = ActiveSimulationRegion(
                    region: merged.region.union(existing.region),
                    remainingSteps: max(merged.remainingSteps, existing.remainingSteps)
                )
                index = result.count - 1
            }
            result.append(merged)
        }
        return result.sorted {
            ($0.region.minY, $0.region.minX) < ($1.region.minY, $1.region.minX)
        }
    }

    private func encode(
        stroke: StrokeCommand,
        slice: Int,
        pointIndexOffset: Int = 0,
        previousPoint initialPreviousPoint: StrokePoint? = nil,
        orientations: [SIMD4<Float>]?,
        with encoder: MTLComputeCommandEncoder
    ) {
        guard !stroke.points.isEmpty else { return }
        if stroke.tool == .smudge || stroke.tool == .smear {
            encodeSmudge(
                stroke: stroke,
                slice: slice,
                previousPoint: initialPreviousPoint,
                with: encoder
            )
            return
        }
        encoder.setComputePipelineState(stampPipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)

        let baseSeed = Self.seed(for: stroke.id)
        for (index, point) in stroke.points.enumerated() {
            let orientation = orientations?[index] ?? SIMD4(1, 0, 0, 0)
            let pressure = Float(min(max(point.pressure, 0), 1))
            let radius = max(Float(stroke.brush.size) * 0.5 * max(pressure, 0.12), 0.5)
            let horizontalRadius = radius * 1.25
            let verticalRadius = radius * 1.25
            let minX = max(Int(floor(point.x - Double(horizontalRadius) - 2)), 0)
            let minY = max(Int(floor(point.y - Double(verticalRadius) - 2)), 0)
            let maxX = min(Int(ceil(point.x + Double(horizontalRadius) + 2)), compositeTexture.width)
            let maxY = min(Int(ceil(point.y + Double(verticalRadius) + 2)), compositeTexture.height)
            guard maxX > minX, maxY > minY else { continue }

            var parameters = StampParameters(
                centerRadius: SIMD4(Float(point.x), Float(point.y), radius, radius),
                color: SIMD4(
                    Float(stroke.brush.color.red),
                    Float(stroke.brush.color.green),
                    Float(stroke.brush.color.blue),
                    Float(stroke.brush.color.alpha)
                ),
                brush: SIMD4(
                    pressure,
                    Float(stroke.brush.opacity),
                    Float(stroke.brush.flow),
                    Float(stroke.brush.water)
                ),
                effects: SIMD4(
                    Float(stroke.brush.granulation),
                    Float(stroke.brush.edgeBloom),
                    Float(point.tiltX),
                    Float(point.tiltY)
                ),
                orientation: orientation,
                dynamics: SIMD4(
                    Self.shapeAspect(for: stroke.brush.shape),
                    Float(stroke.brush.bristleStrength),
                    Float(stroke.brush.textureStrength),
                    0
                ),
                modes: SIMD4(
                    Self.index(of: stroke.tool),
                    Self.index(of: stroke.brush.shape),
                    Self.index(of: stroke.brush.hair),
                    Self.index(of: stroke.brush.texture)
                ),
                extra: SIMD4(
                    Self.index(of: stroke.brush.style),
                    Self.index(of: project.paper),
                    UInt32(slice),
                    baseSeed ^ (UInt32(truncatingIfNeeded: index + pointIndexOffset) &* 0x9e3779b9)
                ),
                behavior: SIMD4(UInt32(stroke.brush.behaviorVersion), 0, 0, 0),
                stampRect: SIMD4(UInt32(minX), UInt32(minY), UInt32(maxX - minX), UInt32(maxY - minY))
            )
            encoder.setBytes(&parameters, length: MemoryLayout<StampParameters>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: maxX - minX, height: maxY - minY, depth: 1),
                threadsPerThreadgroup: threadgroupSize(for: stampPipeline)
            )
            encoder.memoryBarrier(scope: .textures)
        }
    }

    private func encodeSmudge(
        stroke: StrokeCommand,
        slice: Int,
        previousPoint initialPreviousPoint: StrokePoint?,
        with encoder: MTLComputeCommandEncoder
    ) {
        var previousPoint = initialPreviousPoint
        for (index, point) in stroke.points.enumerated() {
            let fallbackNext = stroke.points.indices.contains(index + 1) ? stroke.points[index + 1] : nil
            let reference = previousPoint ?? fallbackNext
            var dx = point.x - (reference?.x ?? point.x - 1)
            var dy = point.y - (reference?.y ?? point.y)
            if previousPoint == nil, let fallbackNext {
                dx = fallbackNext.x - point.x
                dy = fallbackNext.y - point.y
            }
            let length = hypot(dx, dy)
            let direction = length > 0.000_1 ? SIMD2(Float(dx / length), Float(dy / length)) : SIMD2(1, 0)
            let pressure = Float(min(max(point.pressure, 0), 1))
            let radius = max(Float(stroke.brush.size) * 0.5 * max(pressure, 0.12), 0.5) * 1.25
            let padding = Double(radius * (stroke.tool == .smear ? 1.2 : 0.7) + 2)
            let minX = max(Int(floor(point.x - Double(radius) - padding)), 0)
            let minY = max(Int(floor(point.y - Double(radius) - padding)), 0)
            let maxX = min(Int(ceil(point.x + Double(radius) + padding)), compositeTexture.width)
            let maxY = min(Int(ceil(point.y + Double(radius) + padding)), compositeTexture.height)
            guard maxX > minX, maxY > minY else { continue }
            let region = CanvasRegion(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            let destination = 1 - frontTextureIndex
            var parameters = SmudgeParameters(
                centerRadius: SIMD4(Float(point.x), Float(point.y), radius, radius),
                directionStrength: SIMD4(
                    direction.x,
                    direction.y,
                    stroke.tool == .smear ? 0.78 : 0.48,
                    stroke.tool == .smear ? 1.05 : 0.62
                ),
                extra: SIMD4(UInt32(slice), 0, 0, 0),
                stampRect: SIMD4(UInt32(minX), UInt32(minY), UInt32(region.width), UInt32(region.height))
            )
            encoder.setComputePipelineState(smudgePipeline)
            encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
            encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
            encoder.setTexture(pigmentTextures[destination], index: 2)
            encoder.setTexture(wetnessTextures[destination], index: 3)
            encoder.setBytes(&parameters, length: MemoryLayout<SmudgeParameters>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: region.width, height: region.height, depth: 1),
                threadsPerThreadgroup: threadgroupSize(for: smudgePipeline)
            )
            encoder.memoryBarrier(scope: .textures)
            frontTextureIndex = destination
            encodeSynchronize(region: region, targetSlice: UInt32(slice), with: encoder)
            previousPoint = point
        }
    }

    private func encodeSimulation(
        steps: Int,
        targetSlice: UInt32,
        region: CanvasRegion?,
        workBudget: inout RenderWorkBudget,
        with encoder: MTLComputeCommandEncoder
    ) throws {
        guard steps > 0, let region, region.width > 0, region.height > 0 else { return }
        let sliceDepth = targetSlice == Self.allLayers ? layerCapacity : 1
        try workBudget.consume(
            regionArea: region.area,
            steps: steps,
            sliceDepth: sliceDepth,
            passCount: 2
        )
        encoder.setComputePipelineState(simulationPipeline)
        var parameters = SimulationParameters(
            rates: SIMD4(0.24, 0.055, 0.985, 0),
            selection: SIMD4(
                targetSlice,
                Self.index(of: project.paper),
                UInt32(region.minX),
                UInt32(region.minY)
            )
        )
        encoder.setBytes(&parameters, length: MemoryLayout<SimulationParameters>.stride, index: 0)

        for _ in 0..<steps {
            let destination = 1 - frontTextureIndex
            encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
            encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
            encoder.setTexture(pigmentTextures[destination], index: 2)
            encoder.setTexture(wetnessTextures[destination], index: 3)
            encoder.dispatchThreads(
                MTLSize(
                    width: region.width,
                    height: region.height,
                    depth: sliceDepth
                ),
                threadsPerThreadgroup: threadgroupSize(for: simulationPipeline)
            )
            encoder.memoryBarrier(scope: .textures)
            frontTextureIndex = destination
            encodeSynchronize(region: region, targetSlice: targetSlice, with: encoder)
            encoder.setComputePipelineState(simulationPipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<SimulationParameters>.stride, index: 0)
        }
    }

    private func encodeSynchronize(
        region: CanvasRegion,
        targetSlice: UInt32,
        with encoder: MTLComputeCommandEncoder
    ) {
        var parameters = SimulationParameters(
            rates: .zero,
            selection: SIMD4(
                targetSlice,
                Self.index(of: project.paper),
                UInt32(region.minX),
                UInt32(region.minY)
            )
        )
        encoder.setComputePipelineState(synchronizeRegionPipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
        encoder.setTexture(pigmentTextures[1 - frontTextureIndex], index: 2)
        encoder.setTexture(wetnessTextures[1 - frontTextureIndex], index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<SimulationParameters>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(
                width: region.width,
                height: region.height,
                depth: targetSlice == Self.allLayers ? layerCapacity : 1
            ),
            threadsPerThreadgroup: threadgroupSize(for: synchronizeRegionPipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func encodeClear(
        targetSlice: UInt32,
        texturesAt index: Int,
        with encoder: MTLComputeCommandEncoder
    ) {
        encoder.setComputePipelineState(clearPipeline)
        encoder.setTexture(pigmentTextures[index], index: 0)
        encoder.setTexture(wetnessTextures[index], index: 1)
        var targetSlice = targetSlice
        encoder.setBytes(&targetSlice, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: layerCapacity),
            threadsPerThreadgroup: threadgroupSize(for: clearPipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func encodeMerge(
        command: MergeDownCommand,
        source: Int,
        destination: Int,
        with encoder: MTLComputeCommandEncoder
    ) {
        var parameters = MergeParameters(
            slices: SIMD2(UInt32(source), UInt32(destination)),
            opacities: SIMD2(Float(command.sourceOpacity), Float(command.destinationOpacity)),
            visibility: SIMD2(command.sourceIsVisible ? 1 : 0, command.destinationIsVisible ? 1 : 0)
        )
        for textureIndex in pigmentTextures.indices {
            encoder.setComputePipelineState(mergePipeline)
            encoder.setTexture(pigmentTextures[textureIndex], index: 0)
            encoder.setTexture(wetnessTextures[textureIndex], index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<MergeParameters>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
                threadsPerThreadgroup: threadgroupSize(for: mergePipeline)
            )
            encoder.memoryBarrier(scope: .textures)
        }
    }

    private func encodeCopy(source: Int, destination: Int, with encoder: MTLComputeCommandEncoder) {
        var slices = SIMD2(UInt32(source), UInt32(destination))
        for textureIndex in pigmentTextures.indices {
            encoder.setComputePipelineState(copyLayerPipeline)
            encoder.setTexture(pigmentTextures[textureIndex], index: 0)
            encoder.setTexture(wetnessTextures[textureIndex], index: 1)
            encoder.setBytes(&slices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
                threadsPerThreadgroup: threadgroupSize(for: copyLayerPipeline)
            )
            encoder.memoryBarrier(scope: .textures)
        }
    }

    private func encodeComposite(
        with encoder: MTLComputeCommandEncoder,
        project compositeProject: PaintingProject? = nil,
        output: MTLTexture? = nil
    ) {
        let compositeProject = compositeProject ?? project
        let output = output ?? compositeTexture
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(layerMetadataBuffer, offset: 0, index: 0)
        var parameters = CompositeParameters(
            dimensions: SIMD4(
                UInt32(output.width),
                UInt32(output.height),
                Self.index(of: compositeProject.paper),
                UInt32(compositeProject.layers.count)
            )
        )
        encoder.setBytes(&parameters, length: MemoryLayout<CompositeParameters>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: threadgroupSize(for: compositePipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func prepareCompositeTransaction(
        project candidateProject: PaintingProject,
        opacityPreviews: [UUID: Double],
        label: String
    ) throws {
        updateLayerMetadata(project: candidateProject, opacityPreviews: opacityPreviews)
        do {
            let commandBuffer = try makeCommandBuffer(label: label)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.allocation("a layer metadata transaction encoder")
            }
            encoder.label = "Layer metadata transaction composite"
            encodeComposite(
                with: encoder,
                project: candidateProject,
                output: transactionCompositeTexture
            )
            encoder.endEncoding()
            try submit(commandBuffer, wait: true)
        } catch {
            updateLayerMetadata()
            throw error
        }
    }

    private var wetnessTileThreadgroupSize: MTLSize {
        Self.wetnessTileThreadgroupSize(for: wetnessTileMaximumPipeline)
    }

    private var wetnessFinalThreadgroupSize: MTLSize {
        Self.wetnessFinalThreadgroupSize(for: wetnessFinalMaximumPipeline)
    }

    private func prepareCanvasWetnessMeasurement() {
        wetnessMaximumBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
    }

    private func encodeCanvasWetnessMeasurement(with encoder: MTLComputeCommandEncoder) {
        let tileThreadgroupSize = wetnessTileThreadgroupSize
        let tileThreadCount = tileThreadgroupSize.width * tileThreadgroupSize.height
        encoder.setComputePipelineState(wetnessTileMaximumPipeline)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 0)
        encoder.setBuffer(wetnessTileMaximumBuffer, offset: 0, index: 0)
        var activeSlices = project.layers.reduce(UInt32(0)) { mask, layer in
            guard let slice = layerSlices[layer.id] else { return mask }
            return mask | (UInt32(1) << UInt32(slice))
        }
        encoder.setBytes(&activeSlices, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(
            tileThreadCount * MemoryLayout<UInt32>.stride,
            index: 0
        )
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: layerCapacity),
            threadsPerThreadgroup: tileThreadgroupSize
        )
        encoder.memoryBarrier(scope: .buffers)

        let tileCount = Self.wetnessTileCount(
            width: compositeTexture.width,
            height: compositeTexture.height,
            threadsPerThreadgroup: tileThreadgroupSize,
            layerCapacity: layerCapacity
        )
        let finalThreadgroupSize = wetnessFinalThreadgroupSize
        encoder.setComputePipelineState(wetnessFinalMaximumPipeline)
        encoder.setBuffer(wetnessTileMaximumBuffer, offset: 0, index: 0)
        encoder.setBuffer(wetnessMaximumBuffer, offset: 0, index: 1)
        var tileCountParameter = UInt32(tileCount)
        encoder.setBytes(&tileCountParameter, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setThreadgroupMemoryLength(
            finalThreadgroupSize.width * MemoryLayout<UInt32>.stride,
            index: 0
        )
        encoder.dispatchThreads(finalThreadgroupSize, threadsPerThreadgroup: finalThreadgroupSize)
        encoder.memoryBarrier(scope: .buffers)
    }

    private func readCanvasWetnessMeasurement() {
        let maximum = wetnessMaximumBuffer.contents().load(as: UInt32.self)
        canvasWetness = min(max(Double(maximum) / 1_000_000, 0), 1)
    }

    private func makeCommandBuffer(label: String) throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.allocation("a Metal command buffer")
        }
        commandBuffer.label = label
        return commandBuffer
    }

    @discardableResult
    private func trackCommandBuffer(
        _ commandBuffer: MTLCommandBuffer
    ) -> CommandBufferCompletion {
        let completion = CommandBufferCompletion()
        commandBuffer.addCompletedHandler { _ in
            completion.complete()
        }
        lastCommandBuffer = commandBuffer
        lastCommandBufferCompletion = completion
        return completion
    }

    private func submit(_ commandBuffer: MTLCommandBuffer, wait: Bool) throws {
        trackCommandBuffer(commandBuffer)
        commandBuffer.commit()
        if wait {
            commandBuffer.waitUntilCompleted()
            lastCommandBuffer = nil
            lastCommandBufferCompletion = nil
            if let error = commandBufferErrorProvider.error(for: commandBuffer) {
                throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
            }
        }
    }

    private func submitAndWait(_ commandBuffer: MTLCommandBuffer) async throws {
        let provider = commandBufferErrorProvider
        let completion = trackCommandBuffer(commandBuffer)
        commandBuffer.commit()
        await completion.wait()
        if lastCommandBuffer === commandBuffer {
            lastCommandBuffer = nil
            lastCommandBufferCompletion = nil
        }
        if let error = provider.error(for: commandBuffer) {
            throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
        }
    }

    private func synchronizeGPU(readback: Bool) throws {
        guard let commandBuffer = lastCommandBuffer else { return }
        commandBuffer.waitUntilCompleted()
        lastCommandBuffer = nil
        lastCommandBufferCompletion = nil
        if let error = commandBufferErrorProvider.error(for: commandBuffer) {
            if readback {
                throw RendererError.readback(error.localizedDescription)
            }
            throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
        }
    }

    private func synchronizeGPUAsynchronously(readback: Bool) async throws {
        guard let commandBuffer = lastCommandBuffer else { return }
        let provider = commandBufferErrorProvider
        guard let completion = lastCommandBufferCompletion else {
            throw RendererError.allocation("a tracked GPU completion")
        }
        await completion.wait()
        if lastCommandBuffer === commandBuffer {
            lastCommandBuffer = nil
            lastCommandBufferCompletion = nil
        }
        if let error = provider.error(for: commandBuffer) {
            if readback {
                throw RendererError.readback(error.localizedDescription)
            }
            throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
        }
    }

    private func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let width = max(pipeline.threadExecutionWidth, 1)
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
        return MTLSize(width: width, height: height, depth: 1)
    }

    private static func wetnessTileThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let maximumThreads = largestPowerOfTwo(notExceeding: min(pipeline.maxTotalThreadsPerThreadgroup, 256))
        let width = min(max(pipeline.threadExecutionWidth, 1), maximumThreads)
        return MTLSize(width: width, height: max(maximumThreads / width, 1), depth: 1)
    }

    private static func wetnessFinalThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        MTLSize(
            width: largestPowerOfTwo(notExceeding: min(pipeline.maxTotalThreadsPerThreadgroup, 256)),
            height: 1,
            depth: 1
        )
    }

    private static func largestPowerOfTwo(notExceeding limit: Int) -> Int {
        var result = 1
        while result * 2 <= max(limit, 1) {
            result *= 2
        }
        return result
    }

    private static func wetnessTileCount(
        width: Int,
        height: Int,
        threadsPerThreadgroup: MTLSize,
        layerCapacity: Int
    ) -> Int {
        let groupsWide = (width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width
        let groupsHigh = (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height
        return groupsWide * groupsHigh * layerCapacity
    }

    private static func makeWetnessTileMaximumBuffer(device: MTLDevice, length: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
            throw RendererError.allocation("canvas wetness tile maxima")
        }
        buffer.label = "Canvas wetness tile maxima"
        return buffer
    }

    fileprivate static func makeComputePipeline(
        named name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw RendererError.shaderCompilation("Missing function \(name)")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw RendererError.shaderCompilation("\(name): \(error.localizedDescription)")
        }
    }

    fileprivate static func makeDisplayPipeline(
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "displayVertex"),
              let fragment = library.makeFunction(name: "displayFragment")
        else {
            throw RendererError.shaderCompilation("Missing display functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Watercolor display pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.shaderCompilation("display pipeline: \(error.localizedDescription)")
        }
    }

    private static func makeTextures(
        device: MTLDevice,
        width: Int,
        height: Int,
        layerCapacity: Int
    ) throws -> (
        pigment: [MTLTexture],
        wetness: [MTLTexture],
        composite: MTLTexture,
        transactionComposite: MTLTexture
    ) {
        guard width > 0, height > 0 else {
            throw RendererError.allocation("textures for a \(width) × \(height) canvas")
        }

        func makeArray(pixelFormat: MTLPixelFormat, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = pixelFormat
            descriptor.width = width
            descriptor.height = height
            descriptor.depth = 1
            descriptor.mipmapLevelCount = 1
            descriptor.arrayLength = layerCapacity
            descriptor.sampleCount = 1
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.allocation(label)
            }
            texture.label = label
            return texture
        }

        let pigment = try [
            makeArray(pixelFormat: .rgba16Float, label: "Pigment A"),
            makeArray(pixelFormat: .rgba16Float, label: "Pigment B")
        ]
        let wetness = try [
            makeArray(pixelFormat: .r16Float, label: "Wetness A"),
            makeArray(pixelFormat: .r16Float, label: "Wetness B")
        ]

        func makeComposite(label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.allocation(label)
            }
            texture.label = label
            return texture
        }
        return (
            pigment,
            wetness,
            try makeComposite(label: "Watercolor composite"),
            try makeComposite(label: "Watercolor transaction composite")
        )
    }

    private static func makeStrokePreviewSnapshot(
        device: MTLDevice,
        width: Int,
        height: Int
    ) throws -> (pigment: MTLTexture, wetness: MTLTexture) {
        func makeTexture(pixelFormat: MTLPixelFormat, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.allocation(label)
            }
            texture.label = label
            return texture
        }
        return (
            try makeTexture(pixelFormat: .rgba16Float, label: "Committed stroke pigment snapshot"),
            try makeTexture(pixelFormat: .r16Float, label: "Committed stroke wetness snapshot")
        )
    }

    private static func seed(for identifier: UUID) -> UInt32 {
        var uuid = identifier.uuid
        return withUnsafeBytes(of: &uuid) { bytes in
            bytes.reduce(UInt32(2_166_136_261)) { partial, byte in
                (partial ^ UInt32(byte)) &* 16_777_619
            }
        }
    }

    private static func stampOrientations(
        for points: [StrokePoint],
        initialPreviousPoint: StrokePoint?,
        initialSemanticPreviousPoint: StrokePoint?,
        finalSemanticNextPoint: StrokePoint?,
        brush: BrushSettings
    ) -> [SIMD4<Float>]? {
        guard brush.behaviorVersion > 0 else { return nil }
        guard !points.isEmpty else { return [] }

        var orientations = Array(
            repeating: SIMD4<Float>(1, 0, 0, 0),
            count: points.count
        )
        var runStart = points.startIndex
        while runStart < points.endIndex {
            let runPoint = points[runStart]
            var runEnd = points.index(after: runStart)
            while runEnd < points.endIndex,
                  pointsAreCoincident(points[runEnd], runPoint) {
                runEnd = points.index(after: runEnd)
            }

            let previousPoint: StrokePoint?
            if runStart > points.startIndex {
                previousPoint = points[points.index(before: runStart)]
            } else {
                previousPoint = firstNoncoincidentPoint(
                    to: runPoint,
                    in: [initialPreviousPoint, initialSemanticPreviousPoint].compactMap { $0 }
                )
            }
            let nextPoint: StrokePoint?
            if runEnd < points.endIndex {
                nextPoint = points[runEnd]
            } else {
                nextPoint = finalSemanticNextPoint.flatMap {
                    pointsAreCoincident($0, runPoint) ? nil : $0
                }
            }

            for index in runStart..<runEnd {
                orientations[index] = stampOrientation(
                    previous: previousPoint,
                    point: points[index],
                    next: nextPoint,
                    brush: brush
                )
            }
            runStart = runEnd
        }
        return orientations
    }

    private static func preparesStampOrientations(for stroke: StrokeCommand) -> Bool {
        stroke.brush.behaviorVersion > 0
            && stroke.tool != .smudge
            && stroke.tool != .smear
    }

    private static func firstNoncoincidentPoint<C: Sequence>(
        to point: StrokePoint,
        in candidates: C
    ) -> StrokePoint? where C.Element == StrokePoint {
        candidates.first { !pointsAreCoincident($0, point) }
    }

    #if DEBUG
    private static func noncoincidentSearchInspectionCount<C: Sequence>(
        to point: StrokePoint,
        in candidates: C
    ) -> Int where C.Element == StrokePoint {
        var inspectionCount = 0
        for candidate in candidates {
            inspectionCount += 1
            if !pointsAreCoincident(candidate, point) {
                break
            }
        }
        return inspectionCount
    }
    #endif

    private static func pointsAreCoincident(_ lhs: StrokePoint, _ rhs: StrokePoint) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y
    }

    private static func stampOrientation(
        previous: StrokePoint?,
        point: StrokePoint,
        next: StrokePoint?,
        brush: BrushSettings
    ) -> SIMD4<Float> {
        guard brush.behaviorVersion > 0 else {
            return SIMD4(1, 0, 0, 0)
        }

        let base = normalizedVector(dx: point.tiltX, dy: point.tiltY)
            ?? strokeDirection(previous: previous, point: point, next: next)
        let radians = brush.rotation * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotated = SIMD2(
            base.x * cosine - base.y * sine,
            base.x * sine + base.y * cosine
        )
        return SIMD4(
            Float(rotated.x),
            Float(rotated.y),
            Float(radians),
            0
        )
    }

    private static func strokeDirection(
        previous: StrokePoint?,
        point: StrokePoint,
        next: StrokePoint?
    ) -> SIMD2<Double> {
        if let previous, let next,
           let direction = normalizedVector(
               dx: next.x - previous.x,
               dy: next.y - previous.y
           ) {
            return direction
        }
        if let next,
           let direction = normalizedVector(dx: next.x - point.x, dy: next.y - point.y) {
            return direction
        }
        if let previous,
           let direction = normalizedVector(
               dx: point.x - previous.x,
               dy: point.y - previous.y
           ) {
            return direction
        }
        return SIMD2(1, 0)
    }

    private static func normalizedVector(dx: Double, dy: Double) -> SIMD2<Double>? {
        guard dx.isFinite, dy.isFinite else { return nil }
        let magnitude = hypot(dx, dy)
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return SIMD2(dx / magnitude, dy / magnitude)
    }

    private static func shapeAspect(for shape: BrushShape) -> Float {
        switch shape {
        case .round: 1
        case .flat: 1.9
        case .filbert: 2
        case .fan: 1
        case .rigger: 6
        }
    }

    private static func index(of tool: PaintTool) -> UInt32 {
        switch tool {
        case .brush: 0
        case .water: 1
        case .eraser: 2
        case .smudge: 3
        case .smear: 4
        case .dry: 5
        }
    }

    private static func index(of shape: BrushShape) -> UInt32 {
        switch shape {
        case .round: 0
        case .flat: 1
        case .filbert: 2
        case .fan: 3
        case .rigger: 4
        }
    }

    private static func index(of hair: BrushHair) -> UInt32 {
        switch hair {
        case .sable: 0
        case .squirrel: 1
        case .synthetic: 2
        case .bristle: 3
        case .mop: 4
        }
    }

    private static func index(of texture: BrushTexture) -> UInt32 {
        switch texture {
        case .smooth: 0
        case .granulating: 1
        case .dry: 2
        case .mottled: 3
        case .salt: 4
        }
    }

    private static func index(of style: WatercolorStyle) -> UInt32 {
        switch style {
        case .transparentWash: 0
        case .wetOnWet: 1
        case .dryBrush: 2
        case .glazing: 3
        case .bloom: 4
        }
    }

    private static func index(of paper: PaperTexture) -> UInt32 {
        switch paper {
        case .hotPress: 0
        case .coldPress: 1
        case .rough: 2
        case .handmade: 3
        case .canvas: 4
        }
    }
}

@MainActor
private final class RendererPipelineResources {
    let stamp: MTLComputePipelineState
    let simulation: MTLComputePipelineState
    let synchronizeRegion: MTLComputePipelineState
    let smudge: MTLComputePipelineState
    let clear: MTLComputePipelineState
    let copyLayer: MTLComputePipelineState
    let merge: MTLComputePipelineState
    let composite: MTLComputePipelineState
    let wetnessTileMaximum: MTLComputePipelineState
    let wetnessFinalMaximum: MTLComputePipelineState
    let display: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.watercolor, options: nil)
        } catch {
            throw RendererError.shaderCompilation(error.localizedDescription)
        }
        stamp = try WatercolorRenderer.makeComputePipeline(named: "stampKernel", library: library, device: device)
        simulation = try WatercolorRenderer.makeComputePipeline(
            named: "simulationKernel",
            library: library,
            device: device
        )
        synchronizeRegion = try WatercolorRenderer.makeComputePipeline(
            named: "synchronizeRegionKernel",
            library: library,
            device: device
        )
        smudge = try WatercolorRenderer.makeComputePipeline(
            named: "smudgeKernel",
            library: library,
            device: device
        )
        clear = try WatercolorRenderer.makeComputePipeline(named: "clearKernel", library: library, device: device)
        copyLayer = try WatercolorRenderer.makeComputePipeline(
            named: "copyLayerKernel",
            library: library,
            device: device
        )
        merge = try WatercolorRenderer.makeComputePipeline(named: "mergeKernel", library: library, device: device)
        composite = try WatercolorRenderer.makeComputePipeline(
            named: "compositeKernel",
            library: library,
            device: device
        )
        wetnessTileMaximum = try WatercolorRenderer.makeComputePipeline(
            named: "wetnessTileMaximumKernel",
            library: library,
            device: device
        )
        wetnessFinalMaximum = try WatercolorRenderer.makeComputePipeline(
            named: "wetnessFinalMaximumKernel",
            library: library,
            device: device
        )
        display = try WatercolorRenderer.makeDisplayPipeline(library: library, device: device)
    }
}

private struct StampParameters {
    var centerRadius: SIMD4<Float>
    var color: SIMD4<Float>
    var brush: SIMD4<Float>
    var effects: SIMD4<Float>
    /// xy: final unit orientation; z: user rotation in radians; w: reserved.
    var orientation: SIMD4<Float>
    /// x: shape aspect; y: bristle strength; z: texture strength; w: reserved.
    var dynamics: SIMD4<Float>
    var modes: SIMD4<UInt32>
    var extra: SIMD4<UInt32>
    var behavior: SIMD4<UInt32>
    var stampRect: SIMD4<UInt32>
}

private struct SimulationParameters {
    var rates: SIMD4<Float>
    var selection: SIMD4<UInt32>
}

private struct SmudgeParameters {
    var centerRadius: SIMD4<Float>
    var directionStrength: SIMD4<Float>
    var extra: SIMD4<UInt32>
    var stampRect: SIMD4<UInt32>
}

private struct CanvasRegion: Equatable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { max(maxX - minX, 0) }
    var height: Int { max(maxY - minY, 0) }
    var area: Int { width * height }
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    func union(_ other: Self) -> Self {
        Self(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }

    func padded(by amount: Int, canvas: CanvasSize) -> Self {
        Self(
            minX: max(minX - amount, 0),
            minY: max(minY - amount, 0),
            maxX: min(maxX + amount, canvas.width),
            maxY: min(maxY + amount, canvas.height)
        )
    }

    func intersectsOrTouches(_ other: Self) -> Bool {
        minX <= other.maxX && maxX >= other.minX
            && minY <= other.maxY && maxY >= other.minY
    }

    static func forStroke(_ stroke: StrokeCommand, canvas: CanvasSize) -> Self? {
        stroke.points.reduce(nil as Self?) { result, point in
            let pressure = min(max(point.pressure, 0), 1)
            let radius = max(stroke.brush.size * 0.5 * max(pressure, 0.12), 0.5) * 1.25 + 2
            let pointRegion = Self(
                minX: max(Int(floor(point.x - radius)), 0),
                minY: max(Int(floor(point.y - radius)), 0),
                maxX: min(Int(ceil(point.x + radius)), canvas.width),
                maxY: min(Int(ceil(point.y + radius)), canvas.height)
            )
            return result?.union(pointRegion) ?? pointRegion
        }
    }
}

private struct ActiveSimulationRegion: Equatable {
    let region: CanvasRegion
    let remainingSteps: Int
}

private struct SimulationStateSnapshot {
    let frontTextureIndex: Int
    let activeSimulationRegions: [Int: [ActiveSimulationRegion]]
}

private struct SimulationDispatch {
    let slice: Int
    let region: CanvasRegion
    let steps: Int
    let gridDepth: Int
}

private final class CommandBufferErrorProvider: @unchecked Sendable {
    let operation: (MTLCommandBuffer) -> Error?

    init(_ operation: @escaping (MTLCommandBuffer) -> Error?) {
        self.operation = operation
    }

    func error(for commandBuffer: MTLCommandBuffer) -> Error? {
        operation(commandBuffer)
    }
}

private final class CommandBufferCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func complete() {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class StrokePreviewTransaction: @unchecked Sendable {
    let strokeID: UUID
    let token: RendererStrokePreviewToken
    let layerID: UUID
    let layerSlice: Int
    let committedSimulationRegions: [Int: [ActiveSimulationRegion]]
    let strokeTemplate: StrokeCommand
    var completeStroke: StrokeCommand
    var remainder: [StrokePoint]
    var renderedPointCount = 0
    var absolutePointCount: Int
    var lastRenderedPoint: StrokePoint?
    var lastSemanticPreviousPoint: StrokePoint?
    var phase = StrokePreviewPhase.idle
    var workBudget: RenderWorkBudget
    var stagedWorkBudget: RenderWorkBudget?

    private let lock = NSLock()
    private var failure: String?
    private var snapshotCaptureState = StrokePreviewSnapshotState.pending
    private var retainedCancellationSnapshotState: StrokePreviewSnapshotState?
    private var isResolved = false
    private var requiresReplayOnCancel = false

    init(
        stroke: StrokeCommand,
        token: RendererStrokePreviewToken,
        layerSlice: Int,
        committedSimulationRegions: [Int: [ActiveSimulationRegion]],
        workBudget: RenderWorkBudget
    ) {
        strokeID = stroke.id
        self.token = token
        layerID = stroke.layerID
        self.layerSlice = layerSlice
        self.committedSimulationRegions = committedSimulationRegions
        var strokeTemplate = stroke
        strokeTemplate.points = []
        self.strokeTemplate = strokeTemplate
        completeStroke = stroke
        remainder = stroke.points
        absolutePointCount = stroke.points.count
        lastRenderedPoint = nil
        lastSemanticPreviousPoint = nil
        self.workBudget = workBudget
        stagedWorkBudget = nil
    }

    func commitStagedWorkBudget() {
        guard let stagedWorkBudget else { return }
        workBudget = stagedWorkBudget
        self.stagedWorkBudget = nil
    }

    func matchesFinalStroke(_ stroke: StrokeCommand) -> Bool {
        guard stroke.id == strokeID,
              stroke.layerID == layerID,
              stroke.tool == strokeTemplate.tool,
              stroke.brush == strokeTemplate.brush,
              stroke.points.count == absolutePointCount,
              completeStroke.points.count == absolutePointCount
        else { return false }

        guard absolutePointCount > 0 else { return false }
        if absolutePointCount > 1 {
            for index in 0..<(absolutePointCount - 1)
            where completeStroke.points[index] != stroke.points[index] {
                return false
            }
        }
        let storedLast = completeStroke.points[absolutePointCount - 1]
        let finalLast = stroke.points[absolutePointCount - 1]
        return storedLast == finalLast
            || (storedLast.x == finalLast.x && storedLast.y == finalLast.y)
    }

    func record(_ error: Error?) {
        guard let error else { return }
        lock.lock()
        defer { lock.unlock() }
        if failure == nil {
            failure = error.localizedDescription
        }
    }

    func markSnapshotCaptureSubmitted() {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved, snapshotCaptureState == .pending else { return }
        snapshotCaptureState = .submitted
    }

    func markSnapshotCaptureCompleted() {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved, snapshotCaptureState == .submitted else { return }
        snapshotCaptureState = .committed
    }

    func resolveSnapshotCapture() -> StrokePreviewSnapshotState? {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return nil }
        isResolved = true
        return snapshotCaptureState
    }

    func snapshotStateForCancellation() -> StrokePreviewSnapshotState? {
        lock.lock()
        defer { lock.unlock() }
        if let retainedCancellationSnapshotState {
            return retainedCancellationSnapshotState
        }
        guard !isResolved else { return nil }
        isResolved = true
        retainedCancellationSnapshotState = snapshotCaptureState
        return snapshotCaptureState
    }

    func requireReplayOnCancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return }
        requiresReplayOnCancel = true
    }

    var replaysOnCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requiresReplayOnCancel
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

private enum StrokePreviewPhase: Equatable {
    case idle
    case updating
    case finishing
    case cancelling
    case failed
}

private enum StrokePreviewSnapshotState: Equatable {
    case pending
    case submitted
    case committed
}

private struct CompositeParameters {
    var dimensions: SIMD4<UInt32>
}

private struct MergeParameters {
    var slices: SIMD2<UInt32>
    var opacities: SIMD2<Float>
    var visibility: SIMD2<UInt32>
}

private struct ReplayPlan {
    let actions: [ReplayAction]
    let finalLayerSlices: [UUID: Int]
    let layerCapacity: Int
}

private enum ReplayAction {
    case stroke(StrokeCommand, Int)
    case simulateDiscardedStroke(Int)
    case clear(Int)
    case duplicate(Int, Int)
    case merge(MergeDownCommand, Int, Int)
    case dry(Int, Int)
}

#if DEBUG
struct RendererDebugResources: Equatable {
    let pigmentTextures: [ObjectIdentifier]
    let wetnessTextures: [ObjectIdentifier]
    let pipelines: [ObjectIdentifier]
    let compositeTextures: Set<ObjectIdentifier>
    let previewTextures: [ObjectIdentifier]
    let previewTextureAllocationCount: Int
    let previewArrayLength: Int
    let pigmentArrayLength: Int
    let wetnessArrayLength: Int
    let pigmentPixelFormat: MTLPixelFormat
    let wetnessPixelFormat: MTLPixelFormat
    let compositePixelFormat: MTLPixelFormat
}

struct RendererDebugWetnessReductionResources: Equatable {
    let tileMaximumBuffer: ObjectIdentifier
    let finalMaximumBuffer: ObjectIdentifier
    let firstStageThreadgroupCount: Int
    let finalStageThreadgroupCount: Int
}

struct RendererDebugStrokeDispatch: Equatable {
    let stampBatchCount: Int
    let simulationStepCount: Int
    let activeSliceDepth: Int
    let simulationRegion: CGRect
    let simulationThreadCount: Int
    let orientationPreparationPointCount: Int

    static let empty = Self(
        stampBatchCount: 0,
        simulationStepCount: 0,
        activeSliceDepth: 0,
        simulationRegion: .zero,
        simulationThreadCount: 0,
        orientationPreparationPointCount: 0
    )
}

struct RendererDebugPreviewSemanticContextWork: Equatable {
    let nextBoundaryPointCount: Int
    let predecessorSearchPointCount: Int

    static let empty = Self(
        nextBoundaryPointCount: 0,
        predecessorSearchPointCount: 0
    )
}

struct RendererDebugPigmentMoments: Equatable {
    let mass: Double
    let centroidX: Double
    let centroidY: Double
}

struct RendererDebugLayerFields: Equatable {
    let width: Int
    let height: Int
    let pigment: [SIMD4<Float>]
    let wetness: [Float]

    func pigmentColor(x: Int, y: Int) throws -> PaintColor {
        let index = try checkedIndex(x: x, y: y)
        let value = pigment[index]
        return PaintColor(
            red: Double(value.x),
            green: Double(value.y),
            blue: Double(value.z),
            alpha: Double(value.w)
        )
    }

    func wetnessValue(x: Int, y: Int) throws -> Double {
        Double(wetness[try checkedIndex(x: x, y: y)])
    }

    private func checkedIndex(x: Int, y: Int) throws -> Int {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            throw RendererError.readback(
                "Pixel (\(x), \(y)) is outside the \(width) by \(height) debug field"
            )
        }
        return y * width + x
    }
}

struct RendererDebugStampParameterLayout: Equatable {
    let stride: Int
    let centerRadiusOffset: Int
    let colorOffset: Int
    let brushOffset: Int
    let effectsOffset: Int
    let orientationOffset: Int
    let dynamicsOffset: Int
    let modesOffset: Int
    let extraOffset: Int
    let behaviorOffset: Int
    let stampRectOffset: Int
}

extension WatercolorRenderer {
    static var debugStampParameterLayout: RendererDebugStampParameterLayout {
        RendererDebugStampParameterLayout(
            stride: MemoryLayout<StampParameters>.stride,
            centerRadiusOffset: MemoryLayout<StampParameters>.offset(of: \.centerRadius)!,
            colorOffset: MemoryLayout<StampParameters>.offset(of: \.color)!,
            brushOffset: MemoryLayout<StampParameters>.offset(of: \.brush)!,
            effectsOffset: MemoryLayout<StampParameters>.offset(of: \.effects)!,
            orientationOffset: MemoryLayout<StampParameters>.offset(of: \.orientation)!,
            dynamicsOffset: MemoryLayout<StampParameters>.offset(of: \.dynamics)!,
            modesOffset: MemoryLayout<StampParameters>.offset(of: \.modes)!,
            extraOffset: MemoryLayout<StampParameters>.offset(of: \.extra)!,
            behaviorOffset: MemoryLayout<StampParameters>.offset(of: \.behavior)!,
            stampRectOffset: MemoryLayout<StampParameters>.offset(of: \.stampRect)!
        )
    }

    func pixelChecksum() throws -> UInt64 {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The pixel checksum could not access image bytes")
        }
        return (0..<CFDataGetLength(data)).reduce(UInt64(0)) { checksum, index in
            (checksum &* 16_777_619) ^ UInt64(bytes[index])
        }
    }

    var debugResources: RendererDebugResources {
        let previewTextures = [previewPigmentSnapshot, previewWetnessSnapshot]
        return RendererDebugResources(
            pigmentTextures: pigmentTextures.map { ObjectIdentifier($0 as AnyObject) },
            wetnessTextures: wetnessTextures.map { ObjectIdentifier($0 as AnyObject) },
            pipelines: [
                stampPipeline,
                simulationPipeline,
                synchronizeRegionPipeline,
                clearPipeline,
                copyLayerPipeline,
                mergePipeline,
                compositePipeline,
                wetnessTileMaximumPipeline,
                wetnessFinalMaximumPipeline,
                displayPipeline
            ].map { ObjectIdentifier($0 as AnyObject) },
            compositeTextures: [
                ObjectIdentifier(compositeTexture as AnyObject),
                ObjectIdentifier(transactionCompositeTexture as AnyObject)
            ],
            previewTextures: previewTextures.map { ObjectIdentifier($0 as AnyObject) },
            previewTextureAllocationCount: previewTextureAllocationCount,
            previewArrayLength: previewTextures.first?.arrayLength ?? 0,
            pigmentArrayLength: pigmentTextures[0].arrayLength,
            wetnessArrayLength: wetnessTextures[0].arrayLength,
            pigmentPixelFormat: pigmentTextures[0].pixelFormat,
            wetnessPixelFormat: wetnessTextures[0].pixelFormat,
            compositePixelFormat: compositeTexture.pixelFormat
        )
    }

    var debugReplayCount: Int {
        replayCount
    }

    var debugLastStrokeDispatch: RendererDebugStrokeDispatch {
        lastStrokeDispatch
    }

    var debugLastPreviewSemanticContextWork: RendererDebugPreviewSemanticContextWork {
        lastPreviewSemanticContextWork
    }

    var debugLastPreviewFinishEncodedPointCount: Int {
        lastPreviewFinishEncodedPointCount
    }

    var debugSynchronousPreviewCancellationWaitCount: Int {
        synchronousPreviewCancellationWaitCount
    }

    var debugSynchronousPreviewCancellationReplayCount: Int {
        synchronousPreviewCancellationReplayCount
    }

    var debugSynchronousReplaySubmissionCount: Int {
        synchronousReplaySubmissionCount
    }

    var debugWetnessReductionResources: RendererDebugWetnessReductionResources {
        RendererDebugWetnessReductionResources(
            tileMaximumBuffer: ObjectIdentifier(wetnessTileMaximumBuffer as AnyObject),
            finalMaximumBuffer: ObjectIdentifier(wetnessMaximumBuffer as AnyObject),
            firstStageThreadgroupCount: Self.wetnessTileCount(
                width: compositeTexture.width,
                height: compositeTexture.height,
                threadsPerThreadgroup: wetnessTileThreadgroupSize,
                layerCapacity: layerCapacity
            ),
            finalStageThreadgroupCount: 1
        )
    }

    func debugPixel(x: Int, y: Int, layerID: UUID? = nil) throws -> PaintColor {
        let identifier = layerID ?? project.layers.last(where: \.isVisible)?.id ?? project.layers.last?.id
        guard let identifier, let slice = layerSlices[identifier] else {
            throw RendererError.readback("No layer is available for pigment inspection")
        }
        let values = try debugHalfValues(x: x, y: y, slice: slice, texture: pigmentTextures[frontTextureIndex], count: 4)
        return PaintColor(
            red: Double(values[0]),
            green: Double(values[1]),
            blue: Double(values[2]),
            alpha: Double(values[3])
        )
    }

    func debugWetness(x: Int, y: Int, layerID: UUID? = nil) throws -> Double {
        let identifier = layerID ?? project.layers.last(where: \.isVisible)?.id ?? project.layers.last?.id
        guard let identifier, let slice = layerSlices[identifier] else {
            throw RendererError.readback("No layer is available for wetness inspection")
        }
        return Double(try debugHalfValues(
            x: x,
            y: y,
            slice: slice,
            texture: wetnessTextures[frontTextureIndex],
            count: 1
        )[0])
    }

    func debugMaximumWetness() throws -> Double {
        let slices = project.layers.compactMap { layerSlices[$0.id] }
        guard !slices.isEmpty else { return 0 }
        let width = wetnessTextures[frontTextureIndex].width
        let height = wetnessTextures[frontTextureIndex].height
        let bytesPerRow = ((width * MemoryLayout<UInt16>.stride + 255) / 256) * 256
        let bytesPerImage = bytesPerRow * height
        guard let buffer = device.makeBuffer(
            length: bytesPerImage * slices.count,
            options: .storageModeShared
        ) else {
            throw RendererError.readback("Could not allocate the wetness verification buffer")
        }
        let commandBuffer = try makeCommandBuffer(label: "Verify canvas wetness")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the wetness verification encoder")
        }
        for (index, slice) in slices.enumerated() {
            encoder.copy(
                from: wetnessTextures[frontTextureIndex],
                sourceSlice: slice,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: index * bytesPerImage,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerImage
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }

        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var maximum: Float = 0
        for layerIndex in slices.indices {
            for y in 0..<height {
                for x in 0..<width {
                    let byteOffset = layerIndex * bytesPerImage + y * bytesPerRow + x * MemoryLayout<UInt16>.stride
                    let bits = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                    maximum = max(maximum, Float(Float16(bitPattern: bits)))
                }
            }
        }
        return Double(maximum)
    }

    func debugPigmentMoments(layerID: UUID) throws -> RendererDebugPigmentMoments {
        guard let slice = layerSlices[layerID] else {
            throw RendererError.unknownLayer(layerID)
        }
        let texture = pigmentTextures[frontTextureIndex]
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = MemoryLayout<UInt16>.stride * 4
        let bytesPerRow = ((width * bytesPerPixel + 255) / 256) * 256
        let bytesPerImage = bytesPerRow * height
        guard let buffer = device.makeBuffer(length: bytesPerImage, options: .storageModeShared) else {
            throw RendererError.readback("Could not allocate the pigment moment buffer")
        }
        let commandBuffer = try makeCommandBuffer(label: "Measure pigment moments")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the pigment moment encoder")
        }
        encoder.copy(
            from: texture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerImage
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }

        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var mass = 0.0
        var weightedX = 0.0
        var weightedY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let alphaOffset = y * bytesPerRow + x * bytesPerPixel + 3 * MemoryLayout<UInt16>.stride
                let bits = UInt16(bytes[alphaOffset]) | (UInt16(bytes[alphaOffset + 1]) << 8)
                let alpha = Double(Float(Float16(bitPattern: bits)))
                mass += alpha
                weightedX += alpha * Double(x)
                weightedY += alpha * Double(y)
            }
        }
        return RendererDebugPigmentMoments(
            mass: mass,
            centroidX: mass > 0 ? weightedX / mass : 0,
            centroidY: mass > 0 ? weightedY / mass : 0
        )
    }

    func debugLayerFields(layerID: UUID) throws -> RendererDebugLayerFields {
        guard let slice = layerSlices[layerID] else {
            throw RendererError.unknownLayer(layerID)
        }
        let pigmentTexture = pigmentTextures[frontTextureIndex]
        let wetnessTexture = wetnessTextures[frontTextureIndex]
        let width = pigmentTexture.width
        let height = pigmentTexture.height
        guard wetnessTexture.width == width, wetnessTexture.height == height else {
            throw RendererError.readback("Pigment and wetness debug fields have different dimensions")
        }

        let pigmentBytesPerPixel = MemoryLayout<UInt16>.stride * 4
        let wetnessBytesPerPixel = MemoryLayout<UInt16>.stride
        let pigmentBytesPerRow = ((width * pigmentBytesPerPixel + 255) / 256) * 256
        let wetnessBytesPerRow = ((width * wetnessBytesPerPixel + 255) / 256) * 256
        let pigmentBytesPerImage = pigmentBytesPerRow * height
        let wetnessBytesPerImage = wetnessBytesPerRow * height
        let (bufferLength, didOverflow) = pigmentBytesPerImage.addingReportingOverflow(
            wetnessBytesPerImage
        )
        guard !didOverflow,
              let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
        else {
            throw RendererError.readback("Could not allocate the layer field readback buffer")
        }

        let commandBuffer = try makeCommandBuffer(label: "Read watercolor layer fields")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the layer field readback encoder")
        }
        let sourceSize = MTLSize(width: width, height: height, depth: 1)
        encoder.copy(
            from: pigmentTexture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: sourceSize,
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: pigmentBytesPerRow,
            destinationBytesPerImage: pigmentBytesPerImage
        )
        encoder.copy(
            from: wetnessTexture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: sourceSize,
            to: buffer,
            destinationOffset: pigmentBytesPerImage,
            destinationBytesPerRow: wetnessBytesPerRow,
            destinationBytesPerImage: wetnessBytesPerImage
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }

        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        func half(at offset: Int) -> Float {
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            return Float(Float16(bitPattern: bits))
        }
        var pigment = Array(repeating: SIMD4<Float>.zero, count: width * height)
        var wetness = Array(repeating: Float.zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let pigmentOffset = y * pigmentBytesPerRow + x * pigmentBytesPerPixel
                pigment[index] = SIMD4<Float>(
                    half(at: pigmentOffset),
                    half(at: pigmentOffset + 2),
                    half(at: pigmentOffset + 4),
                    half(at: pigmentOffset + 6)
                )
                let wetnessOffset = pigmentBytesPerImage + y * wetnessBytesPerRow + x * wetnessBytesPerPixel
                wetness[index] = half(at: wetnessOffset)
            }
        }
        return RendererDebugLayerFields(
            width: width,
            height: height,
            pigment: pigment,
            wetness: wetness
        )
    }

    private func debugHalfValues(
        x: Int,
        y: Int,
        slice: Int,
        texture: MTLTexture,
        count: Int
    ) throws -> [Float] {
        guard (0..<texture.width).contains(x), (0..<texture.height).contains(y) else {
            throw RendererError.readback("Pixel (\(x), \(y)) is outside the canvas")
        }
        guard let buffer = device.makeBuffer(length: 256, options: .storageModeShared) else {
            throw RendererError.readback("Could not allocate the debug readback buffer")
        }
        let commandBuffer = try makeCommandBuffer(label: "Inspect watercolor pixel")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the debug readback encoder")
        }
        encoder.copy(
            from: texture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: 256,
            destinationBytesPerImage: 256
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }
        let pointer = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<count).map { Float(Float16(bitPattern: pointer[$0])) }
    }
}
#endif
