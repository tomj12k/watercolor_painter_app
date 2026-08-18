import Combine
import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import WatercolorCore
import WatercolorEngine

public struct StudioCapabilities: Equatable, Sendable {
    public var canPaint: Bool
    public var canUndo: Bool
    public var canRedo: Bool

    public init(canPaint: Bool, canUndo: Bool, canRedo: Bool) {
        self.canPaint = canPaint
        self.canUndo = canUndo
        self.canRedo = canRedo
    }
}

public struct StudioFailure: Identifiable, Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case resourceBudget = "WC-RESOURCE-001"
        case workBudget = "WC-WORK-001"
        case capacity = "WC-CAPACITY-001"
        case metalUnavailable = "WC-METAL-001"
        case gpuExecution = "WC-GPU-001"
        case malformedDocument = "WC-DOCUMENT-001"
        case newerDocument = "WC-DOCUMENT-002"
        case export = "WC-EXPORT-001"
        case unknown = "WC-UNKNOWN-001"
    }

    public let id: UUID
    public let code: Code
    public let message: String
    public let recoverySuggestion: String
    public let diagnostic: StudioDiagnostic

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        code = .unknown
        self.message = message
        recoverySuggestion = "Try the operation again. If it continues, copy the details for support."
        diagnostic = .live(errorCode: Code.unknown.rawValue, project: nil)
    }

    public init(
        id: UUID = UUID(),
        code: Code,
        message: String,
        recoverySuggestion: String,
        diagnostic: StudioDiagnostic
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.diagnostic = diagnostic
    }

    public init(error: Error, project: PaintingProject?) {
        let code = Self.code(for: error)
        let diagnostic = StudioDiagnostic.live(errorCode: code.rawValue, project: project)
        self = Self.failure(for: error, code: code, diagnostic: diagnostic)
    }

    /// A deliberate document limit was reached. Unlike unknown failures, the
    /// operation will keep failing on retry, so the recovery guidance must
    /// name the action that actually frees capacity.
    public static func capacity(
        message: String,
        recoverySuggestion: String,
        project: PaintingProject?
    ) -> Self {
        Self(
            code: .capacity,
            message: message,
            recoverySuggestion: recoverySuggestion,
            diagnostic: .live(errorCode: Code.capacity.rawValue, project: project)
        )
    }

    public static func resourceBudget(
        required _: Int,
        available _: Int,
        diagnostic: StudioDiagnostic
    ) -> Self {
        Self(
            code: .resourceBudget,
            message: "This canvas is too large for safe rendering. Your painting is unchanged.",
            recoverySuggestion: "Reduce the canvas size or layer count, then try again.",
            diagnostic: diagnostic
        )
    }

    public static func export(project: PaintingProject?) -> Self {
        let code = Code.export
        return Self(
            code: code,
            message: "Watercolor Studio could not export the image. Your painting is unchanged.",
            recoverySuggestion: "Choose another writable location and try exporting again.",
            diagnostic: .live(errorCode: code.rawValue, project: project)
        )
    }

    public static func rendering(error: Error, project: PaintingProject?) -> Self {
        let mappedCode = code(for: error)
        let code = mappedCode == .unknown ? Code.gpuExecution : mappedCode
        return failure(
            for: error,
            code: code,
            diagnostic: .live(errorCode: code.rawValue, project: project)
        )
    }

    public static func rendererInitialization(error: Error, project: PaintingProject?) -> Self {
        let mappedCode = code(for: error)
        let code = mappedCode == .unknown ? Code.metalUnavailable : mappedCode
        let diagnostic = StudioDiagnostic.live(errorCode: code.rawValue, project: project)
        if code == .gpuExecution {
            return Self(
                code: code,
                message: "Watercolor Studio could not start the watercolor renderer. Your painting is unchanged.",
                recoverySuggestion: "Try again. If it continues, restart the app and check for macOS updates.",
                diagnostic: diagnostic
            )
        }
        return failure(
            for: error,
            code: code,
            diagnostic: diagnostic
        )
    }

    private static func code(for error: Error) -> Code {
        if let rendererError = error as? RendererError {
            switch rendererError {
            case .resourceBudgetExceeded: return .resourceBudget
            case .workBudgetExceeded: return .workBudget
            case .metalUnavailable: return .metalUnavailable
            case .invalidProject: return .malformedDocument
            case .shaderCompilation, .allocation, .unknownLayer, .invalidStrokePreview,
                 .strokePreviewRestoration, .invalidMetadataChange, .readback:
                return .gpuExecution
            }
        }
        if let codecError = error as? DocumentCodecError {
            switch codecError {
            case .malformedData, .validationFailed: return .malformedDocument
            case .unsupportedSchema: return .newerDocument
            }
        }
        return .unknown
    }

    private static func failure(
        for error: Error,
        code: Code,
        diagnostic: StudioDiagnostic
    ) -> Self {
        switch code {
        case .resourceBudget:
            return resourceBudget(required: 0, available: 0, diagnostic: diagnostic)
        case .capacity:
            return Self(
                code: code,
                message: "The project has reached one of its capacity limits. Your painting is unchanged.",
                recoverySuggestion: "Undo strokes, or continue in a new document.",
                diagnostic: diagnostic
            )
        case .workBudget:
            return Self(
                code: code,
                message: "This painting needs more rendering work than Watercolor Studio can safely perform at once. Your painting is unchanged.",
                recoverySuggestion: "Use a smaller canvas, shorter stroke, or fewer drying steps, then try again.",
                diagnostic: diagnostic
            )
        case .metalUnavailable:
            return Self(
                code: code,
                message: "Watercolor Studio could not start the watercolor renderer. Your painting is unchanged.",
                recoverySuggestion: "Try again. If it continues, restart the app and check for macOS updates.",
                diagnostic: diagnostic
            )
        case .gpuExecution:
            return Self(
                code: code,
                message: "The watercolor renderer could not complete that change. Your painting is unchanged.",
                recoverySuggestion: "Try the change again. If it continues, save and reopen the painting.",
                diagnostic: diagnostic
            )
        case .malformedDocument:
            return Self(
                code: code,
                message: "This file is not a valid Watercolor Studio painting and was not opened.",
                recoverySuggestion: "Open a different copy or restore the file from a backup.",
                diagnostic: diagnostic
            )
        case .newerDocument:
            return Self(
                code: code,
                message: "This painting was created by a newer version of Watercolor Studio and was not opened.",
                recoverySuggestion: "Update Watercolor Studio, then open the painting again.",
                diagnostic: diagnostic
            )
        case .export:
            return export(project: nil)
        case .unknown:
            return Self(
                code: code,
                message: "Watercolor Studio could not complete that operation. Your painting is unchanged.",
                recoverySuggestion: "Try again. If it continues, copy the details for support.",
                diagnostic: diagnostic
            )
        }
    }
}

public enum StrokePreviewAdmission: Equatable, Sendable {
    case accepted
    case busy
    case unavailable
}

public enum StudioRendererRecoveryError: Error, Equatable, Sendable {
    case previewRestorationFailed(String)
}

extension StudioRendererRecoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .previewRestorationFailed(message):
            "The watercolor renderer could not restore the painting: \(message)"
        }
    }
}

@MainActor
struct StrokePreviewRendererOperation {
    typealias Update = @MainActor (
        WatercolorRenderer,
        UUID,
        [StrokePoint],
        RendererStrokePreviewToken
    ) async throws -> Void
    typealias Finish = @MainActor (
        WatercolorRenderer,
        StrokeCommand,
        RendererStrokePreviewToken
    ) async throws -> Void
    typealias Cancel = @MainActor (
        WatercolorRenderer,
        RendererStrokePreviewToken
    ) async throws -> Void
    typealias DidProcessUpdateFailure = @MainActor (Error) async -> Void

    let update: Update
    let finish: Finish
    let cancel: Cancel
    let didProcessUpdateFailure: DidProcessUpdateFailure

    init(
        update: @escaping Update,
        finish: @escaping Finish,
        cancel: @escaping Cancel = { renderer, token in
            try await renderer.restoreStrokePreviewCancellation(token)
        },
        didProcessUpdateFailure: @escaping DidProcessUpdateFailure = { _ in }
    ) {
        self.update = update
        self.finish = finish
        self.cancel = cancel
        self.didProcessUpdateFailure = didProcessUpdateFailure
    }

    static let live = Self(
        update: { renderer, id, points, token in
            try await renderer.appendStrokePreview(id: id, points: points, token: token)
        },
        finish: { renderer, stroke, token in
            try await renderer.finishStrokePreview(stroke, token: token)
        },
        cancel: { renderer, token in
            try await renderer.restoreStrokePreviewCancellation(token)
        }
    )
}

// CGImage is immutable after creation, so this readback snapshot can safely cross to the export worker.
struct StudioPNGImageSnapshot: @unchecked Sendable {
    let image: CGImage
}

struct StudioPNGExportWorker: Sendable {
    typealias Operation = @Sendable (StudioPNGImageSnapshot, URL, URL) async throws -> Void

    private let operation: Operation

    init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    func export(
        _ snapshot: StudioPNGImageSnapshot,
        to temporaryURL: URL,
        for destinationURL: URL
    ) async throws {
        try await operation(snapshot, temporaryURL, destinationURL)
    }

    static let live = Self { snapshot, temporaryURL, _ in
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StudioCoordinationError.pngEncoding
        }
        CGImageDestinationAddImage(destination, snapshot.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StudioCoordinationError.pngEncoding
        }
        try (data as Data).write(to: temporaryURL, options: .atomic)
    }
}

struct StudioPNGExportTicket: Sendable {
    let destinationURL: URL
    let temporaryURL: URL
    fileprivate let generation: UUID
}

actor StudioPNGExportCoordinator {
    static let shared = StudioPNGExportCoordinator()

    private var latestGenerationByDestination: [URL: UUID] = [:]

    func beginExport(to destinationURL: URL) -> StudioPNGExportTicket {
        let standardizedDestination = destinationURL.standardizedFileURL
        let generation = UUID()
        latestGenerationByDestination[standardizedDestination] = generation
        let temporaryURL = standardizedDestination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(standardizedDestination.lastPathComponent).watercolor-export-\(generation.uuidString).tmp"
            )
        return StudioPNGExportTicket(
            destinationURL: standardizedDestination,
            temporaryURL: temporaryURL,
            generation: generation
        )
    }

    func commit(_ ticket: StudioPNGExportTicket) throws -> Bool {
        guard latestGenerationByDestination[ticket.destinationURL] == ticket.generation else {
            removeTemporaryFile(for: ticket)
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: ticket.destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    ticket.destinationURL,
                    withItemAt: ticket.temporaryURL
                )
            } else {
                try FileManager.default.moveItem(
                    at: ticket.temporaryURL,
                    to: ticket.destinationURL
                )
            }
            latestGenerationByDestination.removeValue(forKey: ticket.destinationURL)
            return true
        } catch {
            latestGenerationByDestination.removeValue(forKey: ticket.destinationURL)
            removeTemporaryFile(for: ticket)
            throw error
        }
    }

    func discard(_ ticket: StudioPNGExportTicket) {
        if latestGenerationByDestination[ticket.destinationURL] == ticket.generation {
            latestGenerationByDestination.removeValue(forKey: ticket.destinationURL)
        }
        removeTemporaryFile(for: ticket)
    }

    private func removeTemporaryFile(for ticket: StudioPNGExportTicket) {
        guard FileManager.default.fileExists(atPath: ticket.temporaryURL.path) else { return }
        try? FileManager.default.removeItem(at: ticket.temporaryURL)
    }
}

@MainActor
public final class StudioModel: ObservableObject {
    public static let brushSizeRange = 1.0...300.0
    private static let dryStepCount = 24
    // Drain the queued input backlog in large adaptive appends so paint
    // catches up to a fast cursor: the renderer splits each append into
    // bounded GPU submissions itself, so per-submission safety no longer
    // limits the drain size. The cap keeps cancellation responsive and the
    // canvas refreshing every append while a backlog drains, instead of
    // one long append that repaints only at its end.
    //
    // Must stay a whole multiple of WatercolorRenderer.stampBatchSize: wet
    // simulation runs between stamp batches, so a drain size off the batch
    // stride would shift batch boundaries and make live-preview pixels
    // diverge from replay and reopen. A test pins this relationship.
    static let previewPointDrainLimit = 64
    private static let maximumRendererCheckpointCount = 2
    private static let defaultRendererCheckpointByteBudget = 256 * 1024 * 1024

    @Published public private(set) var project: PaintingProject
    @Published public var selectedLayerID: UUID {
        didSet { refreshCapabilities() }
    }
    @Published public var selectedTool: PaintTool {
        didSet {
            guard oldValue != selectedTool else { return }
            storedToolSettings[oldValue] = brush
            brush = storedToolSettings[selectedTool] ?? Self.defaultBrush(for: selectedTool)
        }
    }
    @Published public var brush: BrushSettings

    /// Each tool keeps its own settings, so adjusting the eraser never
    /// disturbs the brush. Settings for tools not yet visited come from
    /// `defaultBrush(for:)`.
    private var storedToolSettings: [PaintTool: BrushSettings] = [:]

    /// Strength tools start at full strength — the exact behavior they had
    /// while their strength was fixed — so nothing feels different until
    /// the customer moves the slider.
    static func defaultBrush(for tool: PaintTool) -> BrushSettings {
        var settings = BrushSettings.default
        switch tool {
        case .brush, .water:
            break
        case .eraser, .smudge, .smear, .dry:
            settings.opacity = 1
        }
        return settings
    }
    @Published public var zoom: CGFloat
    @Published public var pan: CGSize
    @Published public private(set) var error: StudioFailure?
    /// A routine limit the customer ran into — a stroke ended at capacity, a
    /// refused stroke, or queued strokes that expired. These are expected
    /// events, so they inform from the canvas activity area instead of
    /// interrupting with a modal alert; `error` stays reserved for failures.
    @Published public private(set) var notice: StudioFailure?
    @Published public private(set) var rendererRecoveryError: StudioRendererRecoveryError?
    @Published public private(set) var capabilities: StudioCapabilities
    /// Non-modal notice shown from 90% of any document limit, so the customer
    /// learns about the ceiling before a stroke is refused at the wall.
    @Published public private(set) var capacityWarning: String?
    /// True while a structural change (such as a new paper surface) replays
    /// the painting in the background with editing paused; the studio shows
    /// why the pause is happening while this is set.
    @Published public private(set) var isApplyingSurfaceChange = false

    /// The paper the customer chose, applied or still preparing. The picker
    /// shows this value so a click is reflected immediately; it falls back
    /// to the project's paper when a change fails or none is pending.
    @Published private var pendingPaper: PaperTexture?

    public var displayedPaper: PaperTexture {
        pendingPaper ?? project.paper
    }
    @Published public private(set) var canvasWetness: Double
    @Published public private(set) var layerOpacityPreviews: [UUID: Double]
    @Published public private(set) var recentColors: [PaintColor]

    public var onDocumentUpdate: ((PaintingProject) -> Void)?

    var rendererProject: PaintingProject {
        renderer.project
    }

    var rendererIdentity: ObjectIdentifier {
        ObjectIdentifier(renderer)
    }

    #if DEBUG
    var rendererForTesting: WatercolorRenderer {
        renderer
    }

    var rendererCheckpointCountForTesting: Int {
        rendererCheckpoints.count
    }

    var rendererCheckpointBytesForTesting: Int {
        rendererCheckpoints.reduce(0) { $0 + $1.estimatedBytes }
    }
    #endif

    public var canAddLayer: Bool {
        canModifyProject && project.layers.count < PaintingProject.maximumLayerCount
    }

    public var canDuplicateSelectedLayer: Bool {
        canAddLayer && selectedLayerIndex != nil
    }

    public var canDeleteSelectedLayer: Bool {
        canModifyProject && project.layers.count > 1 && selectedLayerIndex != nil
    }

    public var canMoveSelectedLayerUp: Bool {
        guard canModifyProject else { return false }
        guard let selectedLayerIndex else { return false }
        return selectedLayerIndex < project.layers.count - 1
    }

    public var canMoveSelectedLayerDown: Bool {
        guard canModifyProject else { return false }
        guard let selectedLayerIndex else { return false }
        return selectedLayerIndex > 0
    }

    public var canMergeSelectedLayerDown: Bool {
        canMoveSelectedLayerDown
    }

    private var renderer: WatercolorRenderer
    private let canvasDelegate: CanvasRendererDelegate
    private var editor: ProjectEditor
    private let pngExportWorker: StudioPNGExportWorker
    private let pngExportCoordinator: StudioPNGExportCoordinator
    private let strokePreviewOperation: StrokePreviewRendererOperation
    private var latestPNGExportID: UUID?
    private var currentPNGExportFailureID: UUID?
    private weak var attachedCanvas: MTKView?
    private var strokePreviewState: StudioStrokePreviewState
    private var pendingStrokePreviewPoints: [StrokePoint]
    private var pendingStrokePreviewOffset: Int
#if DEBUG
    private(set) var pendingStrokePreviewCompactionCountForTesting = 0
#endif
    private var strokePreviewDrainTask: Task<Void, Never>?
    private var strokePreviewDrainToken: StudioStrokePreviewToken?
    private var strokePreviewCancellationTask: Task<Void, Never>?
    private var rendererCheckpoints: [RendererCheckpoint]
    private let rendererCheckpointByteBudget: Int
    private let projectAdmissionLimits: ProjectAdmissionLimits
    private var structuralReplacementTask: Task<Void, Never>?

    public var isStrokePreviewActive: Bool {
        strokePreviewState.token != nil
    }

    public var canModifyProject: Bool {
        strokePreviewState.token == nil && !isApplyingSurfaceChange
    }

    var isStrokePreviewFinalizing: Bool {
        if case .finalizing = strokePreviewState { return true }
        return false
    }

    var pendingStrokePreviewPointCountForTesting: Int {
        pendingStrokePreviewPoints.count - pendingStrokePreviewOffset
    }

    private var canAppendCommand: Bool {
        project.commands.count < projectAdmissionLimits.maximumCommandCount
    }

    var maximumPointCountForNewStroke: Int {
        min(PaintingProject.maximumStrokePointCount, remainingStrokePointCapacity)
    }

    public convenience init(
        project: PaintingProject,
        onDocumentUpdate: ((PaintingProject) -> Void)? = nil
    ) throws {
        let renderer = try WatercolorRenderer(project: project)
        self.init(project: project, renderer: renderer, onDocumentUpdate: onDocumentUpdate)
    }

    init(
        project: PaintingProject,
        renderer: WatercolorRenderer,
        onDocumentUpdate: ((PaintingProject) -> Void)? = nil,
        pngExportWorker: StudioPNGExportWorker = .live,
        pngExportCoordinator: StudioPNGExportCoordinator = .shared,
        rendererCheckpointByteBudget: Int = StudioModel.defaultRendererCheckpointByteBudget,
        strokePreviewOperation: StrokePreviewRendererOperation = .live,
        maximumCommandCount: Int = PaintingProject.maximumCommandCount,
        maximumTotalStrokePointCount: Int = PaintingProject.maximumTotalStrokePointCount,
        maximumSerializedStorageBytes: Int = PaintingProject.maximumSerializedStorageBytes
    ) {
        editor = ProjectEditor(project: project)
        self.project = project
        selectedLayerID = project.layers[0].id
        selectedTool = .brush
        brush = .default
        zoom = 1
        pan = .zero
        error = nil
        notice = nil
        rendererRecoveryError = nil
        capabilities = StudioCapabilities(canPaint: true, canUndo: false, canRedo: false)
        capacityWarning = nil
        canvasWetness = renderer.canvasWetness
        layerOpacityPreviews = [:]
        recentColors = []
        self.renderer = renderer
        self.pngExportWorker = pngExportWorker
        self.pngExportCoordinator = pngExportCoordinator
        self.strokePreviewOperation = strokePreviewOperation
        latestPNGExportID = nil
        currentPNGExportFailureID = nil
        strokePreviewState = .idle
        pendingStrokePreviewPoints = []
        pendingStrokePreviewOffset = 0
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
        strokePreviewCancellationTask = nil
        rendererCheckpoints = []
        self.rendererCheckpointByteBudget = max(rendererCheckpointByteBudget, 0)
        projectAdmissionLimits = ProjectAdmissionLimits(
            maximumCommandCount: maximumCommandCount,
            maximumTotalStrokePointCount: maximumTotalStrokePointCount,
            maximumSerializedStorageBytes: maximumSerializedStorageBytes
        )
        canvasDelegate = CanvasRendererDelegate(renderer: renderer)
        self.onDocumentUpdate = onDocumentUpdate
        refreshCapabilities()
    }

    @discardableResult
    func beginStrokePreview(_ stroke: StrokeCommand) -> StrokePreviewAdmission {
        guard !isApplyingSurfaceChange else { return .busy }
        guard strokePreviewState.token == nil else { return .busy }
        guard rendererRecoveryError == nil,
              canAppendStroke(stroke),
              project.layers.contains(where: { $0.id == stroke.layerID })
        else { return .unavailable }
        let previewRenderer = renderer
        do {
            let rendererToken = try previewRenderer.beginStrokePreview(stroke)
            let token = nextStrokePreviewToken(
                for: stroke.id,
                renderer: previewRenderer,
                rendererToken: rendererToken
            )
            strokePreviewState = .active(token)
            refreshCapabilities()
            error = nil
            notice = nil
            return .accepted
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
            return .unavailable
        }
    }

    func appendStrokePreview(id: UUID, points: [StrokePoint]) {
        guard case let .active(token) = strokePreviewState,
              token.strokeID == id,
              renderer === token.renderer,
              !points.isEmpty
        else { return }
        if pendingStrokePreviewOffset == pendingStrokePreviewPoints.count {
            let hadConsumedStorage = pendingStrokePreviewOffset > 0
            pendingStrokePreviewPoints.removeAll(keepingCapacity: true)
            pendingStrokePreviewOffset = 0
#if DEBUG
            if hadConsumedStorage { pendingStrokePreviewCompactionCountForTesting += 1 }
#endif
        }
        pendingStrokePreviewPoints.append(contentsOf: points)
        startStrokePreviewDrainIfNeeded()
    }

    func commitStrokePreview(_ stroke: StrokeCommand) async {
        guard case let .active(token) = strokePreviewState,
              token.strokeID == stroke.id,
              renderer === token.renderer
        else { return }
        strokePreviewState = .finalizing(token)
        refreshCapabilities()
        startStrokePreviewDrainIfNeeded()
        await waitForStrokePreviewIdle(token: token)
        guard isFinalizingStrokePreview(token), renderer === token.renderer else { return }
        guard canAppendStroke(stroke) else {
            await cancelStrokePreviewAfterAdmissionFailure(token: token)
            if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
            return
        }
        do {
            try await strokePreviewOperation.finish(token.renderer, stroke, token.rendererToken)
            guard isFinalizingStrokePreview(token), renderer === token.renderer else { return }
            try token.renderer.recordRenderedStroke(stroke)
            canvasWetness = token.renderer.canvasWetness
            editor.append(.stroke(stroke))
            strokePreviewState = .idle
            clearPendingStrokePreviewPoints()
            publishEditorProject()
            error = nil
        } catch {
            guard isFinalizingStrokePreview(token), renderer === token.renderer else { return }
            let failure = StudioFailure.rendering(error: error, project: project)
            if case RendererError.strokePreviewRestoration = error {
                invalidateStrokePreview(token)
                enterRendererRecovery(error)
            } else {
                do {
                    try await token.renderer.restoreStrokePreviewCancellation(
                        token.rendererToken
                    )
                    guard isFinalizingStrokePreview(token),
                          renderer === token.renderer
                    else { return }
                    try await token.renderer.replayAsynchronously(project: project)
                    guard isFinalizingStrokePreview(token),
                          renderer === token.renderer
                    else { return }
                    invalidateStrokePreview(token)
                    self.error = failure
                } catch {
                    guard isFinalizingStrokePreview(token),
                          renderer === token.renderer
                    else { return }
                    invalidateStrokePreview(token)
                    enterRendererRecovery(error)
                }
            }
        }
        refreshCapabilities()
        if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
    }

    /// Reports strokes that waited for the renderer but never obtained it.
    /// A routine loss report, so it lands on the notice channel.
    func noteDroppedDeferredStrokes(count: Int) {
        guard count > 0 else { return }
        let subject = count == 1 ? "A queued stroke" : "\(count) queued strokes"
        notice = StudioFailure(
            message: "\(subject) could not be painted because the renderer stayed busy."
        )
    }

    /// Explains why a capacity-ended stroke stopped, without disturbing a
    /// failure that the commit itself already reported.
    func noteStrokeExhaustion(_ reason: StrokeExhaustionReason) {
        guard error == nil else { return }
        notice = StudioFailure.capacity(
            message: reason.message,
            recoverySuggestion: reason.recoverySuggestion,
            project: project
        )
    }

    func cancelStrokePreview(reason: StrokeExhaustionReason? = nil) {
        guard let token = strokePreviewState.token else { return }
        guard !isCancellingStrokePreview(token) else { return }
        let wasFinalizing = isFinalizingStrokePreview(token)
        beginStrokePreviewCancellation(
            token: token,
            wasFinalizing: wasFinalizing,
            failure: reason.map {
                StudioFailure.capacity(
                    message: $0.cancellationMessage,
                    recoverySuggestion: $0.cancellationRecoverySuggestion,
                    project: project
                )
            }
        )
        refreshCapabilities()
        if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
    }

    func waitForStrokePreviewCancellation() async {
        while let task = strokePreviewCancellationTask {
            await task.value
            if strokePreviewCancellationTask == nil { return }
        }
    }

    func waitForStrokePreviewIdle() async {
        guard let token = strokePreviewState.token else { return }
        await waitForStrokePreviewIdle(token: token)
    }

    private func startStrokePreviewDrainIfNeeded() {
        guard strokePreviewDrainTask == nil,
              let token = strokePreviewState.token,
              pendingStrokePreviewOffset < pendingStrokePreviewPoints.count
        else { return }

        strokePreviewDrainToken = token
        strokePreviewDrainTask = Task { @MainActor [weak self] in
            await self?.drainStrokePreviewUpdates(token: token)
        }
    }

    private func drainStrokePreviewUpdates(token: StudioStrokePreviewToken) async {
        while !Task.isCancelled,
              isCurrentStrokePreview(token),
              renderer === token.renderer,
              pendingStrokePreviewOffset < pendingStrokePreviewPoints.count {
            let availablePointCount = pendingStrokePreviewPoints.count - pendingStrokePreviewOffset
            let pointCount = min(Self.previewPointDrainLimit, availablePointCount)
            let end = pendingStrokePreviewOffset + pointCount
            let points = Array(pendingStrokePreviewPoints[pendingStrokePreviewOffset..<end])
            pendingStrokePreviewOffset = end
            if pendingStrokePreviewOffset == pendingStrokePreviewPoints.count {
                pendingStrokePreviewPoints.removeAll(keepingCapacity: true)
                pendingStrokePreviewOffset = 0
#if DEBUG
                pendingStrokePreviewCompactionCountForTesting += 1
#endif
            }
            do {
                try await strokePreviewOperation.update(
                    token.renderer,
                    token.strokeID,
                    points,
                    token.rendererToken
                )
                guard isCurrentStrokePreview(token), renderer === token.renderer else { break }
                error = nil
                if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
            } catch {
                guard isCurrentStrokePreview(token), renderer === token.renderer else { break }
                failStrokePreview(error, token: token)
                await strokePreviewOperation.didProcessUpdateFailure(error)
                break
            }
        }

        guard strokePreviewDrainToken == token else { return }
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
        startStrokePreviewDrainIfNeeded()
    }

    private func waitForStrokePreviewIdle(token: StudioStrokePreviewToken) async {
        while isCurrentStrokePreview(token) {
            startStrokePreviewDrainIfNeeded()
            guard strokePreviewDrainToken == token,
                  let task = strokePreviewDrainTask
            else { return }
            await task.value
            guard isCurrentStrokePreview(token), renderer === token.renderer else { return }
        }
    }

    private func failStrokePreview(
        _ previewError: Error,
        token: StudioStrokePreviewToken
    ) {
        let wasFinalizing: Bool
        switch strokePreviewState {
        case let .active(current) where current == token:
            wasFinalizing = false
        case let .finalizing(current) where current == token:
            wasFinalizing = true
        default:
            return
        }
        beginStrokePreviewCancellation(
            token: token,
            wasFinalizing: wasFinalizing,
            failure: StudioFailure.rendering(error: previewError, project: project)
        )
        refreshCapabilities()
    }

    private func beginStrokePreviewCancellation(
        token: StudioStrokePreviewToken,
        wasFinalizing: Bool,
        failure: StudioFailure?
    ) {
        switch strokePreviewState {
        case let .active(current) where current == token,
             let .finalizing(current) where current == token:
            break
        default:
            return
        }
        strokePreviewState = .cancelling(token)
        clearPendingStrokePreviewPoints()
        strokePreviewDrainTask?.cancel()
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
        let operation = strokePreviewOperation
        let committedProject = project
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            do {
                try await operation.cancel(token.renderer, token.rendererToken)
                if wasFinalizing {
                    try await token.renderer.replayAsynchronously(project: committedProject)
                }
                guard let self, self.isCancellingStrokePreview(token) else { return }
                self.strokePreviewState = .idle
                self.error = failure
            } catch {
                guard let self, self.isCancellingStrokePreview(token) else { return }
                self.strokePreviewState = .idle
                self.enterRendererRecovery(error)
            }
            guard let self else { return }
            self.strokePreviewCancellationTask = nil
            self.refreshCapabilities()
            if let attachedCanvas = self.attachedCanvas {
                self.updateCanvasDisplay(attachedCanvas)
            }
        }
        strokePreviewCancellationTask = task
    }

    func completeStroke(_ stroke: StrokeCommand) {
        guard canModifyProject, canAppendStroke(stroke) else { return }
        guard project.layers.contains(where: { $0.id == stroke.layerID }) else {
            error = StudioFailure(
                message: "The selected layer is no longer available. Choose another layer and try again."
            )
            return
        }

        do {
            try renderer.renderAndRecord(stroke: stroke)
            canvasWetness = renderer.canvasWetness
            editor.append(.stroke(stroke))
            publishEditorProject()
            error = nil
        } catch {
            let failure = StudioFailure.rendering(error: error, project: project)
            do {
                try renderer.replay(project: project)
                self.error = failure
            } catch {
                enterRendererRecovery(error)
                refreshCapabilities()
            }
        }
    }

    private func reportCommandCapacityFailure() {
        notice = StudioFailure.capacity(
            message: "The project has reached its command capacity of \(projectAdmissionLimits.maximumCommandCount).",
            recoverySuggestion: "Undo strokes, or continue in a new document.",
            project: project
        )
    }

    private func canAppendStroke(_ stroke: StrokeCommand) -> Bool {
        guard rendererRecoveryError == nil else { return false }
        guard canAppendCommand else {
            reportCommandCapacityFailure()
            return false
        }
        do {
            try project.validateForRendering(
                adding: stroke,
                limits: projectAdmissionLimits
            )
        } catch let validationError as ProjectValidationError {
            switch validationError {
            case .commandLimitExceeded:
                reportCommandCapacityFailure()
            case .totalStrokePointLimitExceeded:
                notice = StudioFailure.capacity(
                    message: "The project has reached its point capacity of \(projectAdmissionLimits.maximumTotalStrokePointCount).",
                    recoverySuggestion: "Undo strokes, or continue in a new document.",
                    project: project
                )
            case .documentByteLimitExceeded:
                notice = StudioFailure.capacity(
                    message: "The project has reached its document storage capacity.",
                    recoverySuggestion: "Use a shorter stroke, or undo strokes before continuing.",
                    project: project
                )
            default:
                error = StudioFailure.rendering(
                    error: RendererError.invalidProject(validationError),
                    project: project
                )
            }
            return false
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
            return false
        }
        return true
    }

    private var remainingStrokePointCapacity: Int {
        var totalPointCount = 0
        for command in project.commands {
            guard case let .stroke(stroke) = command else { continue }
            let (updatedTotal, didOverflow) = totalPointCount.addingReportingOverflow(stroke.points.count)
            guard !didOverflow else { return 0 }
            totalPointCount = updatedTotal
        }
        return max(projectAdmissionLimits.maximumTotalStrokePointCount - totalPointCount, 0)
    }

    private func cancelStrokePreviewAfterAdmissionFailure(
        token: StudioStrokePreviewToken
    ) async {
        guard isFinalizingStrokePreview(token) else { return }
        let admissionFailure = error
        beginStrokePreviewCancellation(
            token: token,
            wasFinalizing: false,
            failure: admissionFailure
        )
        refreshCapabilities()
        await waitForStrokePreviewCancellation()
    }

    private func nextStrokePreviewToken(
        for strokeID: UUID,
        renderer: WatercolorRenderer,
        rendererToken: RendererStrokePreviewToken
    ) -> StudioStrokePreviewToken {
        return StudioStrokePreviewToken(
            strokeID: strokeID,
            renderer: renderer,
            rendererToken: rendererToken
        )
    }

    private func invalidateStrokePreview(_ token: StudioStrokePreviewToken) {
        guard isCurrentStrokePreview(token) else { return }
        strokePreviewState = .idle
        clearPendingStrokePreviewPoints()
        strokePreviewDrainTask?.cancel()
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
    }

    private func clearPendingStrokePreviewPoints() {
        pendingStrokePreviewPoints.removeAll(keepingCapacity: true)
        pendingStrokePreviewOffset = 0
#if DEBUG
        pendingStrokePreviewCompactionCountForTesting += 1
#endif
    }

    private func isCurrentStrokePreview(_ token: StudioStrokePreviewToken) -> Bool {
        strokePreviewState.token == token
    }

    private func isFinalizingStrokePreview(_ token: StudioStrokePreviewToken) -> Bool {
        guard case let .finalizing(current) = strokePreviewState else { return false }
        return current == token
    }

    private func isCancellingStrokePreview(_ token: StudioStrokePreviewToken) -> Bool {
        guard case let .cancelling(current) = strokePreviewState else { return false }
        return current == token
    }

    private func enterRendererRecovery(_ recoveryCause: Error) {
        let recoveryError = StudioRendererRecoveryError.previewRestorationFailed(
            recoveryCause.localizedDescription
        )
        rendererRecoveryError = recoveryError
        rendererCheckpoints.removeAll()
        // The recovery banner carries the message and the Try Again control.
        // Raising a modal alert here as well would cover that control, so
        // recovery reports through the banner alone.
    }

    public func addLayer() {
        guard canAddLayer else { return }
        let name = nextLayerName()
        performProjectEdit(
            { editor in try editor.addLayer(named: name) },
            selecting: { $0.layers.last?.id }
        )
    }

    public func duplicateSelectedLayer() {
        guard canDuplicateSelectedLayer, let selectedIndex = selectedLayerIndex else { return }
        let name = "\(project.layers[selectedIndex].name) copy"
        performProjectEdit(
            { editor in
                try editor.duplicateLayer(id: selectedLayerID, named: name)
            },
            selecting: { project in
                let duplicateIndex = selectedIndex + 1
                guard project.layers.indices.contains(duplicateIndex) else { return nil }
                return project.layers[duplicateIndex].id
            }
        )
    }

    public func deleteSelectedLayer() {
        guard canDeleteSelectedLayer, let selectedIndex = selectedLayerIndex else { return }
        let layerID = selectedLayerID
        performProjectEdit(
            { editor in try editor.removeLayer(id: layerID) },
            selecting: { project in
                let replacementIndex = min(selectedIndex, project.layers.count - 1)
                return project.layers[replacementIndex].id
            }
        )
    }

    public func moveSelectedLayerUp() {
        guard let selectedLayerIndex, canMoveSelectedLayerUp else { return }
        let layerID = selectedLayerID
        performMetadataEdit(
            { editor in try editor.moveLayer(id: layerID, to: selectedLayerIndex + 1) },
            selecting: { _ in layerID }
        )
    }

    public func moveSelectedLayerDown() {
        guard let selectedLayerIndex, canMoveSelectedLayerDown else { return }
        let layerID = selectedLayerID
        performMetadataEdit(
            { editor in try editor.moveLayer(id: layerID, to: selectedLayerIndex - 1) },
            selecting: { _ in layerID }
        )
    }

    public func moveLayer(id: UUID, toLayerID: UUID) {
        guard id != toLayerID,
              project.layers.contains(where: { $0.id == id }),
              let destinationIndex = project.layers.firstIndex(where: { $0.id == toLayerID })
        else { return }
        performMetadataEdit(
            { editor in try editor.moveLayer(id: id, to: destinationIndex) },
            selecting: { _ in id }
        )
    }

    public func renameLayer(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let selectedLayerID = selectedLayerID
        performMetadataEdit(
            { editor in try editor.renameLayer(id: id, to: trimmedName) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
    }

    public func setLayerVisibility(id: UUID, isVisible: Bool) {
        let selectedLayerID = selectedLayerID
        performMetadataEdit(
            { editor in try editor.setLayerVisibility(id: id, isVisible: isVisible) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
    }

    public func setLayerOpacity(id: UUID, opacity: Double) {
        guard opacity.isFinite else { return }
        let clampedOpacity = min(max(opacity, 0), 1)
        let selectedLayerID = selectedLayerID
        performMetadataEdit(
            { editor in try editor.setLayerOpacity(id: id, opacity: clampedOpacity) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
    }

    public func previewLayerOpacity(id: UUID, opacity: Double) {
        guard canModifyProject,
              opacity.isFinite,
              project.layers.contains(where: { $0.id == id })
        else { return }
        let clampedOpacity = min(max(opacity, 0), 1)
        do {
            try renderer.previewLayerOpacity(id: id, opacity: clampedOpacity)
            layerOpacityPreviews[id] = clampedOpacity
            error = nil
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
        }
    }

    public func displayedLayerOpacity(id: UUID) -> Double {
        layerOpacityPreviews[id]
            ?? project.layers.first(where: { $0.id == id })?.opacity
            ?? 1
    }

    public func commitLayerOpacity(id: UUID) {
        guard canModifyProject,
              let opacity = layerOpacityPreviews[id]
        else { return }
        let selectedLayerID = selectedLayerID
        let didCommit = performMetadataEdit(
            { editor in try editor.setLayerOpacity(id: id, opacity: opacity) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
        let shouldClearPreview = !didCommit
            || renderer.project.layers.first(where: { $0.id == id })?.opacity == opacity
        if shouldClearPreview {
            do {
                try renderer.clearLayerOpacityPreview(id: id)
            } catch {
                enterRendererRecovery(error)
                refreshCapabilities()
            }
        }
        layerOpacityPreviews.removeValue(forKey: id)
    }

    public func mergeSelectedLayerDown() {
        guard let selectedLayerIndex, canMergeSelectedLayerDown else { return }
        let sourceLayerID = selectedLayerID
        let destinationLayerID = project.layers[selectedLayerIndex - 1].id
        performProjectEdit(
            { editor in try editor.mergeDown(id: sourceLayerID) },
            selecting: { _ in destinationLayerID }
        )
    }

    public func clearSelectedLayer() {
        guard selectedLayerIndex != nil else { return }
        let layerID = selectedLayerID
        performProjectEdit(
            { editor in editor.append(.clearLayer(LayerCommand(layerID: layerID))) },
            selecting: { _ in layerID }
        )
    }

    /// Applies a paper change without blocking the main thread. The change
    /// requires a full deterministic replay under the new surface, so editing
    /// pauses while the replay runs asynchronously and the project publishes
    /// only when the replacement renderer is ready — a failure leaves the
    /// painting untouched, exactly like the synchronous edit paths.
    public func selectPaper(_ paper: PaperTexture) {
        guard canModifyProject else { return }
        let selectedLayerID = selectedLayerID
        var updatedEditor = editor
        updatedEditor.setPaper(paper)
        let updatedProject = updatedEditor.project
        guard updatedProject != project else { return }

        isApplyingSurfaceChange = true
        pendingPaper = paper
        refreshCapabilities()
        let preparedCheckpoint = rendererRecoveryError == nil
            ? prepareCurrentRendererCheckpointForCandidateAllocation()
            : nil
        structuralReplacementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidateRenderer = try await self.makeRendererCandidateAsynchronously(
                    project: updatedProject
                )
                if let preparedCheckpoint {
                    self.appendRendererCheckpoint(preparedCheckpoint)
                }
                self.isApplyingSurfaceChange = false
                self.pendingPaper = nil
                self.replaceRenderer(with: candidateRenderer)
                self.publishSuccessfulEdit(
                    editor: updatedEditor,
                    project: updatedProject,
                    selectedLayerID: updatedProject.layers.first(
                        where: { $0.id == selectedLayerID }
                    )?.id
                )
            } catch {
                self.isApplyingSurfaceChange = false
                self.pendingPaper = nil
                self.error = StudioFailure.rendering(error: error, project: self.project)
                self.refreshCapabilities()
            }
            self.structuralReplacementTask = nil
        }
    }

    func waitForStructuralChanges() async {
        while let task = structuralReplacementTask {
            await task.value
            if structuralReplacementTask == nil { return }
        }
    }

    /// Builds a replacement renderer for `project` while keeping the main
    /// thread schedulable: the candidate starts from an empty command list
    /// (cheap), then replays the full history through the renderer's
    /// asynchronous replay, which waits on GPU completion without blocking.
    private func makeRendererCandidateAsynchronously(
        project candidateProject: PaintingProject
    ) async throws -> WatercolorRenderer {
        var blankProject = candidateProject
        blankProject.commands = []
        let retainedBytes = rendererCheckpoints.reduce(into: 0) { total, checkpoint in
            let (updatedTotal, didOverflow) = total.addingReportingOverflow(
                checkpoint.estimatedBytes
            )
            total = didOverflow ? .max : updatedTotal
        }
        do {
            let candidateRenderer = try renderer.makeCandidate(
                project: blankProject,
                retainedCheckpointBytes: retainedBytes
            )
            try await candidateRenderer.replayAsynchronously(project: candidateProject)
            return candidateRenderer
        } catch RendererError.resourceBudgetExceeded where retainedBytes > 0 {
            rendererCheckpoints.removeAll()
            let candidateRenderer = try renderer.makeCandidate(project: blankProject)
            try await candidateRenderer.replayAsynchronously(project: candidateProject)
            return candidateRenderer
        }
    }

    public func setBrushSize(_ size: Double) {
        guard size.isFinite else { return }
        brush.size = min(max(size, Self.brushSizeRange.lowerBound), Self.brushSizeRange.upperBound)
    }

    public func setBrushSpacing(_ spacing: Double) {
        guard spacing.isFinite else { return }
        brush.spacing = min(max(spacing, 0.08), 0.60)
    }

    public func setBrushRotation(_ rotation: Double) {
        guard rotation.isFinite else { return }
        brush.rotation = min(max(rotation, -180), 180)
    }

    public func setBristleStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        brush.bristleStrength = min(max(strength, 0), 1)
    }

    public func setTextureStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        brush.textureStrength = min(max(strength, 0), 1)
    }

    public func resetBrushDynamics() {
        brush.spacing = 0.18
        brush.rotation = 0
        brush.bristleStrength = 0.50
        brush.textureStrength = 0.50
    }

    public func adjustBrushSize(by amount: Double) {
        setBrushSize(brush.size + amount)
    }

    public func selectStyle(_ style: WatercolorStyle) {
        brush = brush.applying(style)
    }

    public func selectPickerColor(_ color: PaintColor) {
        guard color.red.isFinite, color.green.isFinite, color.blue.isFinite, color.alpha.isFinite else {
            return
        }
        brush.color = color
        recentColors.removeAll { existing in
            [
                abs(existing.red - color.red),
                abs(existing.green - color.green),
                abs(existing.blue - color.blue),
                abs(existing.alpha - color.alpha)
            ].max()! < 1.0 / 255.0
        }
        recentColors.insert(color, at: 0)
        if recentColors.count > 6 {
            recentColors.removeLast(recentColors.count - 6)
        }
    }

    @discardableResult
    public func selectTool(forShortcut shortcut: String) -> Bool {
        let tool: PaintTool
        switch shortcut.lowercased() {
        case "b": tool = .brush
        case "e": tool = .eraser
        case "w": tool = .water
        case "s": tool = .smudge
        case "m": tool = .smear
        case "d": tool = .dry
        default: return false
        }
        selectedTool = tool
        return true
    }

    public func fitCanvas() {
        zoom = 1
        pan = .zero
    }

    public func undo() {
        guard editor.canUndo else { return }
        performHistoryMove { editor in
            _ = editor.undo()
        }
    }

    public func redo() {
        guard editor.canRedo else { return }
        performHistoryMove { editor in
            _ = editor.redo()
        }
    }

    /// Rebuilds the renderer from the committed project after a renderer
    /// failure, restoring painting without requiring a structural edit. A
    /// failed rebuild keeps the recovery state and reports why.
    public func retryRendererRecovery() {
        guard rendererRecoveryError != nil else { return }
        do {
            let candidateRenderer = try makeRendererCandidate(project: project)
            replaceRenderer(with: candidateRenderer)
            refreshCapabilities()
            error = nil
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
        }
    }

    public func drySelectedLayer() {
        guard selectedLayerIndex != nil else { return }
        let layerID = selectedLayerID
        performProjectEdit(
            { editor in
                editor.append(.dryLayer(DryLayerCommand(
                    layerID: layerID,
                    steps: Self.dryStepCount
                )))
            },
            selecting: { _ in layerID }
        )
    }

    public func exportPNG(to destinationURL: URL) async {
        let exportID = UUID()
        latestPNGExportID = exportID
        // A paper change the customer already chose must be in the file:
        // wait for the in-flight replacement renderer before snapshotting,
        // so the export can never write the old surface to disk.
        await waitForStructuralChanges()
        guard latestPNGExportID == exportID else { return }
        let capturedFailureID = error?.id
        let capturedExportFailureID = currentPNGExportFailureID
        let exportTicket = await pngExportCoordinator.beginExport(to: destinationURL)

        do {
            let snapshot = StudioPNGImageSnapshot(image: try renderer.makeCGImage())
            let worker = pngExportWorker
            try await Task.detached(priority: .userInitiated) {
                try await worker.export(
                    snapshot,
                    to: exportTicket.temporaryURL,
                    for: exportTicket.destinationURL
                )
            }.value
            guard try await pngExportCoordinator.commit(exportTicket) else { return }
            guard latestPNGExportID == exportID,
                  error?.id == capturedFailureID
            else { return }
            if let capturedExportFailureID,
               capturedFailureID == capturedExportFailureID {
                error = nil
                currentPNGExportFailureID = nil
            }
        } catch {
            await pngExportCoordinator.discard(exportTicket)
            guard latestPNGExportID == exportID,
                  self.error?.id == capturedFailureID
            else { return }
            let failure = StudioFailure.export(project: project)
            self.error = failure
            currentPNGExportFailureID = failure.id
        }
    }

    public func dismissError() {
        error = nil
    }

    public func dismissNotice() {
        notice = nil
    }

    @discardableResult
    func replaceProjectFromDocument(_ replacement: PaintingProject) -> Bool {
        guard canModifyProject else { return false }
        guard replacement != project else { return true }

        do {
            try replacement.validate()
            rendererCheckpoints.removeAll()
            let candidateRenderer = try makeRendererCandidate(project: replacement)
            let nextSelection = replacement.layers.contains(where: { $0.id == selectedLayerID })
                ? selectedLayerID
                : replacement.layers[0].id
            editor = ProjectEditor(project: replacement)
            project = replacement
            selectedLayerID = nextSelection
            replaceRenderer(with: candidateRenderer)
            refreshCapabilities()
            error = nil
            return true
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
            return false
        }
    }

    public func configureCanvas(_ view: MTKView) {
        attachedCanvas = view
        view.device = renderer.renderedTexture.device
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = canvasDelegate
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        updateCanvasDisplay(view)
    }

    func updateCanvasDisplay(_ view: MTKView) {
        renderer.configureDisplay(zoom: zoom, pan: pan)
        view.setNeedsDisplay(view.bounds)
    }

    private func publishEditorProject() {
        project = editor.project
        refreshCapabilities()
        onDocumentUpdate?(project)
    }

    private func performHistoryMove(_ move: (inout ProjectEditor) -> Void) {
        guard canModifyProject else { return }
        var updatedEditor = editor
        move(&updatedEditor)
        let updatedProject = updatedEditor.project
        let nextSelection = updatedProject.layers.contains(where: { $0.id == selectedLayerID })
            ? selectedLayerID
            : updatedProject.layers[0].id

        do {
            if rendererRecoveryError == nil,
               let checkpointRenderer = takeRendererCheckpoint(for: updatedProject) {
                replaceRenderer(with: checkpointRenderer, checkpointCurrent: true)
            } else {
                rendererCheckpoints.removeAll()
                let candidateRenderer = try makeRendererCandidate(project: updatedProject)
                replaceRenderer(with: candidateRenderer)
            }
            publishSuccessfulEdit(
                editor: updatedEditor,
                project: updatedProject,
                selectedLayerID: nextSelection
            )
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
        }
    }

    @discardableResult
    private func performProjectEdit(
        _ edit: (inout ProjectEditor) throws -> Void,
        selecting selection: (PaintingProject) -> UUID?
    ) -> Bool {
        guard canModifyProject else { return false }
        let previousProject = project
        var updatedEditor = editor

        do {
            try edit(&updatedEditor)
            let updatedProject = updatedEditor.project
            guard updatedProject != previousProject else { return true }
            let preparedCheckpoint = rendererRecoveryError == nil
                ? prepareCurrentRendererCheckpointForCandidateAllocation()
                : nil
            let candidateRenderer = try makeRendererCandidate(project: updatedProject)
            if let preparedCheckpoint {
                appendRendererCheckpoint(preparedCheckpoint)
            }
            replaceRenderer(with: candidateRenderer)
            publishSuccessfulEdit(
                editor: updatedEditor,
                project: updatedProject,
                selectedLayerID: selection(updatedProject)
            )
            return true
        } catch {
            let failure = StudioFailure.rendering(error: error, project: project)
            self.error = failure
            return false
        }
    }

    @discardableResult
    private func performMetadataEdit(
        _ edit: (inout ProjectEditor) throws -> Void,
        selecting selection: (PaintingProject) -> UUID?
    ) -> Bool {
        guard canModifyProject else { return false }
        let previousProject = project
        var updatedEditor = editor

        do {
            try edit(&updatedEditor)
            let updatedProject = updatedEditor.project
            guard updatedProject != previousProject else { return true }
            if rendererRecoveryError == nil {
                try renderer.applyMetadata(project: updatedProject)
            } else {
                rendererCheckpoints.removeAll()
                let candidateRenderer = try makeRendererCandidate(project: updatedProject)
                replaceRenderer(with: candidateRenderer)
            }
            publishSuccessfulEdit(
                editor: updatedEditor,
                project: updatedProject,
                selectedLayerID: selection(updatedProject)
            )
            if let attachedCanvas {
                updateCanvasDisplay(attachedCanvas)
            }
            return true
        } catch {
            self.error = StudioFailure.rendering(error: error, project: project)
            return false
        }
    }

    private func publishSuccessfulEdit(
        editor: ProjectEditor,
        project: PaintingProject,
        selectedLayerID: UUID?
    ) {
        self.editor = editor
        self.project = project
        self.selectedLayerID = selectedLayerID ?? self.selectedLayerID
        layerOpacityPreviews.removeAll()
        refreshCapabilities()
        onDocumentUpdate?(project)
        error = nil
        notice = nil
    }

    private func replaceRenderer(
        with renderer: WatercolorRenderer,
        checkpointCurrent: Bool = false
    ) {
        if checkpointCurrent {
            storeRendererCheckpoint(project: project, renderer: self.renderer)
        }
        self.renderer = renderer
        rendererRecoveryError = nil
        canvasWetness = renderer.canvasWetness
        layerOpacityPreviews.removeAll()
        canvasDelegate.replaceRenderer(with: renderer)
        guard let attachedCanvas else { return }
        attachedCanvas.device = renderer.renderedTexture.device
        updateCanvasDisplay(attachedCanvas)
    }

    private func storeRendererCheckpoint(project: PaintingProject, renderer: WatercolorRenderer) {
        guard rendererRecoveryError == nil else { return }
        let checkpoint = RendererCheckpoint(
            project: project,
            renderer: renderer,
            estimatedBytes: renderer.estimatedResourceBytes
        )
        guard checkpoint.estimatedBytes <= rendererCheckpointByteBudget else {
            rendererCheckpoints.removeAll()
            return
        }
        rendererCheckpoints.removeAll { checkpoint in
            checkpoint.project == project || checkpoint.renderer === renderer
        }
        evictRendererCheckpoints(toFit: checkpoint.estimatedBytes)
        appendRendererCheckpoint(checkpoint)
    }

    private func makeRendererCandidate(
        project: PaintingProject
    ) throws -> WatercolorRenderer {
        let retainedBytes = rendererCheckpoints.reduce(into: 0) { total, checkpoint in
            let (updatedTotal, didOverflow) = total.addingReportingOverflow(
                checkpoint.estimatedBytes
            )
            total = didOverflow ? .max : updatedTotal
        }
        do {
            return try renderer.makeCandidate(
                project: project,
                retainedCheckpointBytes: retainedBytes
            )
        } catch RendererError.resourceBudgetExceeded where retainedBytes > 0 {
            rendererCheckpoints.removeAll()
            return try renderer.makeCandidate(project: project)
        }
    }

    private func prepareCurrentRendererCheckpointForCandidateAllocation() -> RendererCheckpoint? {
        let checkpoint = RendererCheckpoint(
            project: project,
            renderer: renderer,
            estimatedBytes: renderer.estimatedResourceBytes
        )
        rendererCheckpoints.removeAll { existing in
            existing.project == project || existing.renderer === renderer
        }
        guard checkpoint.estimatedBytes <= rendererCheckpointByteBudget else {
            rendererCheckpoints.removeAll()
            return nil
        }
        evictRendererCheckpoints(toFit: checkpoint.estimatedBytes)
        return checkpoint
    }

    private func evictRendererCheckpoints(toFit additionalBytes: Int) {
        while !rendererCheckpoints.isEmpty,
              rendererCheckpoints.reduce(additionalBytes, { $0 + $1.estimatedBytes })
                > rendererCheckpointByteBudget {
            rendererCheckpoints.removeFirst()
        }
    }

    private func appendRendererCheckpoint(_ checkpoint: RendererCheckpoint) {
        rendererCheckpoints.append(checkpoint)
        while rendererCheckpoints.count > Self.maximumRendererCheckpointCount {
            rendererCheckpoints.removeFirst()
        }
    }

    private func takeRendererCheckpoint(for project: PaintingProject) -> WatercolorRenderer? {
        guard let index = rendererCheckpoints.lastIndex(where: { $0.project == project }) else {
            return nil
        }
        return rendererCheckpoints.remove(at: index).renderer
    }

    private func nextLayerName() -> String {
        let existingNames = Set(project.layers.map(\.name))
        var number = project.layers.count + 1
        while existingNames.contains("Layer \(number)") {
            number += 1
        }
        return "Layer \(number)"
    }

    private var selectedLayerIndex: Int? {
        project.layers.firstIndex(where: { $0.id == selectedLayerID })
    }

    private func refreshCapabilities() {
        capabilities = StudioCapabilities(
            canPaint: rendererRecoveryError == nil
                && !isApplyingSurfaceChange
                && !isStrokePreviewFinalizing
                && !strokePreviewState.isCancelling
                && project.layers.contains(where: { $0.id == selectedLayerID }),
            canUndo: canModifyProject && editor.canUndo,
            canRedo: canModifyProject && editor.canRedo
        )
        capacityWarning = Self.capacityWarning(for: project, limits: projectAdmissionLimits)
    }

    private static func capacityWarning(
        for project: PaintingProject,
        limits: ProjectAdmissionLimits
    ) -> String? {
        func fraction(_ used: Int, of maximum: Int) -> Double {
            guard maximum > 0 else { return 1 }
            return Double(used) / Double(maximum)
        }
        var totalPointCount = 0
        for command in project.commands {
            guard case let .stroke(stroke) = command else { continue }
            let (updatedTotal, didOverflow) = totalPointCount
                .addingReportingOverflow(stroke.points.count)
            guard !didOverflow else {
                totalPointCount = .max
                break
            }
            totalPointCount = updatedTotal
        }
        let storageCharge = (try? project.serializedStorageCharge()) ?? .max
        let usage = max(
            fraction(project.commands.count, of: limits.maximumCommandCount),
            fraction(totalPointCount, of: limits.maximumTotalStrokePointCount),
            fraction(storageCharge, of: limits.maximumSerializedStorageBytes)
        )
        guard usage >= 0.9 else { return nil }
        let percent = min(Int((usage * 100).rounded(.down)), 100)
        return "Painting history is \(percent)% full. Undo strokes, or continue in a new document."
    }

}

private struct StudioStrokePreviewToken: Equatable {
    let strokeID: UUID
    let renderer: WatercolorRenderer
    let rendererToken: RendererStrokePreviewToken

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.strokeID == rhs.strokeID
            && lhs.renderer === rhs.renderer
            && lhs.rendererToken == rhs.rendererToken
    }
}

private enum StudioStrokePreviewState {
    case idle
    case active(StudioStrokePreviewToken)
    case finalizing(StudioStrokePreviewToken)
    case cancelling(StudioStrokePreviewToken)

    var token: StudioStrokePreviewToken? {
        switch self {
        case .idle: nil
        case let .active(token), let .finalizing(token), let .cancelling(token): token
        }
    }

    var isCancelling: Bool {
        if case .cancelling = self { return true }
        return false
    }
}

@MainActor
private struct RendererCheckpoint {
    let project: PaintingProject
    let renderer: WatercolorRenderer
    let estimatedBytes: Int
}

@MainActor
private final class CanvasRendererDelegate: NSObject, MTKViewDelegate {
    private var renderer: WatercolorRenderer

    init(renderer: WatercolorRenderer) {
        self.renderer = renderer
    }

    func replaceRenderer(with renderer: WatercolorRenderer) {
        self.renderer = renderer
    }

    func draw(in view: MTKView) {
        renderer.draw(in: view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.mtkView(view, drawableSizeWillChange: size)
    }
}

private enum StudioCoordinationError: LocalizedError {
    case pngEncoding

    var errorDescription: String? {
        switch self {
        case .pngEncoding:
            "Image I/O could not encode the composited canvas."
        }
    }
}
