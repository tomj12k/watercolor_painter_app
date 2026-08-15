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
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
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
        StrokeCommand,
        RendererStrokePreviewToken
    ) async throws -> Void
    typealias Finish = @MainActor (
        WatercolorRenderer,
        StrokeCommand,
        RendererStrokePreviewToken
    ) async throws -> Void

    let update: Update
    let finish: Finish

    static let live = Self(
        update: { renderer, stroke, token in
            try await renderer.updateStrokePreview(stroke, token: token)
        },
        finish: { renderer, stroke, token in
            try await renderer.finishStrokePreview(stroke, token: token)
        }
    )
}

// CGImage is immutable after creation, so this readback snapshot can safely cross to the export worker.
struct StudioPNGImageSnapshot: @unchecked Sendable {
    let image: CGImage
}

struct StudioPNGExportWorker: Sendable {
    typealias Operation = @Sendable (StudioPNGImageSnapshot, URL) async throws -> Void

    private let operation: Operation

    init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    func export(_ snapshot: StudioPNGImageSnapshot, to destinationURL: URL) async throws {
        try await operation(snapshot, destinationURL)
    }

    static let live = Self { snapshot, destinationURL in
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
        try (data as Data).write(to: destinationURL, options: .atomic)
    }
}

@MainActor
public final class StudioModel: ObservableObject {
    public static let brushSizeRange = 1.0...300.0
    private static let dryStepCount = 24
    private static let maximumRendererCheckpointCount = 2
    private static let defaultRendererCheckpointByteBudget = 256 * 1024 * 1024

    @Published public private(set) var project: PaintingProject
    @Published public var selectedLayerID: UUID {
        didSet { refreshCapabilities() }
    }
    @Published public var selectedTool: PaintTool
    @Published public var brush: BrushSettings
    @Published public var zoom: CGFloat
    @Published public var pan: CGSize
    @Published public private(set) var error: StudioFailure?
    @Published public private(set) var rendererRecoveryError: StudioRendererRecoveryError?
    @Published public private(set) var capabilities: StudioCapabilities
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
    private let strokePreviewOperation: StrokePreviewRendererOperation
    private var latestPNGExportID: UUID?
    private var currentPNGExportFailureID: UUID?
    private weak var attachedCanvas: MTKView?
    private var strokePreviewState: StudioStrokePreviewState
    private var pendingStrokePreview: StrokeCommand?
    private var strokePreviewDrainTask: Task<Void, Never>?
    private var strokePreviewDrainToken: StudioStrokePreviewToken?
    private var rendererCheckpoints: [RendererCheckpoint]
    private let rendererCheckpointByteBudget: Int

    public var isStrokePreviewActive: Bool {
        strokePreviewState.token != nil
    }

    public var canModifyProject: Bool {
        strokePreviewState.token == nil
    }

    var isStrokePreviewFinalizing: Bool {
        if case .finalizing = strokePreviewState { return true }
        return false
    }

    private var canAppendCommand: Bool {
        project.commands.count < PaintingProject.maximumCommandCount
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
        rendererCheckpointByteBudget: Int = StudioModel.defaultRendererCheckpointByteBudget,
        strokePreviewOperation: StrokePreviewRendererOperation = .live
    ) {
        editor = ProjectEditor(project: project)
        self.project = project
        selectedLayerID = project.layers[0].id
        selectedTool = .brush
        brush = .default
        zoom = 1
        pan = .zero
        error = nil
        rendererRecoveryError = nil
        capabilities = StudioCapabilities(canPaint: true, canUndo: false, canRedo: false)
        canvasWetness = renderer.canvasWetness
        layerOpacityPreviews = [:]
        recentColors = []
        self.renderer = renderer
        self.pngExportWorker = pngExportWorker
        self.strokePreviewOperation = strokePreviewOperation
        latestPNGExportID = nil
        currentPNGExportFailureID = nil
        strokePreviewState = .idle
        pendingStrokePreview = nil
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
        rendererCheckpoints = []
        self.rendererCheckpointByteBudget = max(rendererCheckpointByteBudget, 0)
        canvasDelegate = CanvasRendererDelegate(renderer: renderer)
        self.onDocumentUpdate = onDocumentUpdate
        refreshCapabilities()
    }

    @discardableResult
    func beginStrokePreview(_ stroke: StrokeCommand) -> StrokePreviewAdmission {
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
            pendingStrokePreview = stroke
            startStrokePreviewDrainIfNeeded()
            refreshCapabilities()
            error = nil
            return .accepted
        } catch {
            self.error = StudioFailure(message: error.localizedDescription)
            return .unavailable
        }
    }

    func updateStrokePreview(_ stroke: StrokeCommand) {
        guard case let .active(token) = strokePreviewState,
              token.strokeID == stroke.id,
              renderer === token.renderer
        else { return }
        pendingStrokePreview = stroke
        startStrokePreviewDrainIfNeeded()
    }

    func commitStrokePreview(_ stroke: StrokeCommand) async {
        guard case let .active(token) = strokePreviewState,
              token.strokeID == stroke.id,
              renderer === token.renderer
        else { return }
        strokePreviewState = .finalizing(token)
        refreshCapabilities()
        pendingStrokePreview = stroke
        startStrokePreviewDrainIfNeeded()
        await waitForStrokePreviewIdle(token: token)
        guard isFinalizingStrokePreview(token), renderer === token.renderer else { return }
        guard canAppendStroke(stroke) else {
            cancelStrokePreviewAfterAdmissionFailure(token: token)
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
            pendingStrokePreview = nil
            publishEditorProject()
            error = nil
        } catch {
            guard isFinalizingStrokePreview(token), renderer === token.renderer else { return }
            let failure = StudioFailure(message: error.localizedDescription)
            invalidateStrokePreview(token)
            if case RendererError.strokePreviewRestoration = error {
                enterRendererRecovery(error)
            } else {
                do {
                    try token.renderer.replay(project: project)
                    self.error = failure
                } catch {
                    enterRendererRecovery(error)
                }
            }
        }
        refreshCapabilities()
        if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
    }

    func cancelStrokePreview() {
        guard let token = strokePreviewState.token else { return }
        let wasFinalizing = isFinalizingStrokePreview(token)
        invalidateStrokePreview(token)
        do {
            try token.renderer.cancelStrokePreview(token.rendererToken)
            if wasFinalizing {
                try token.renderer.replay(project: project)
            }
            error = nil
        } catch {
            enterRendererRecovery(error)
        }
        refreshCapabilities()
        if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
    }

    func waitForStrokePreviewIdle() async {
        guard let token = strokePreviewState.token else { return }
        await waitForStrokePreviewIdle(token: token)
    }

    private func startStrokePreviewDrainIfNeeded() {
        guard strokePreviewDrainTask == nil,
              let token = strokePreviewState.token,
              pendingStrokePreview?.id == token.strokeID
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
              let stroke = pendingStrokePreview,
              stroke.id == token.strokeID {
            pendingStrokePreview = nil
            do {
                try await strokePreviewOperation.update(
                    token.renderer,
                    stroke,
                    token.rendererToken
                )
                guard isCurrentStrokePreview(token), renderer === token.renderer else { break }
                error = nil
                if let attachedCanvas { updateCanvasDisplay(attachedCanvas) }
            } catch {
                guard isCurrentStrokePreview(token), renderer === token.renderer else { break }
                failStrokePreview(error, token: token)
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
        guard isCurrentStrokePreview(token) else { return }
        invalidateStrokePreview(token)
        do {
            try token.renderer.cancelStrokePreview(token.rendererToken)
            error = StudioFailure(message: previewError.localizedDescription)
        } catch {
            enterRendererRecovery(error)
        }
        refreshCapabilities()
    }

    func completeStroke(_ stroke: StrokeCommand) {
        guard canModifyProject, canAppendStroke(stroke) else { return }
        guard project.layers.contains(where: { $0.id == stroke.layerID }) else {
            error = StudioFailure(
                message: StudioCoordinationError.strokeLayerUnavailable(stroke.layerID).localizedDescription
            )
            return
        }

        do {
            try renderer.renderAndWait(stroke: stroke)
            try renderer.recordRenderedStroke(stroke)
            canvasWetness = renderer.canvasWetness
            editor.append(.stroke(stroke))
            publishEditorProject()
            error = nil
        } catch {
            let failure = StudioFailure(message: error.localizedDescription)
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
        error = StudioFailure(
            message: "The project has reached its command capacity of \(PaintingProject.maximumCommandCount)."
        )
    }

    private func canAppendStroke(_ stroke: StrokeCommand) -> Bool {
        guard rendererRecoveryError == nil else { return false }
        guard canAppendCommand else {
            reportCommandCapacityFailure()
            return false
        }
        guard prospectiveStrokePointCapacityError(for: stroke) == nil else {
            error = StudioFailure(
                message: "The project has reached its point capacity of \(PaintingProject.maximumTotalStrokePointCount)."
            )
            return false
        }
        return true
    }

    private func prospectiveStrokePointCapacityError(
        for stroke: StrokeCommand
    ) -> ProjectValidationError? {
        var totalPointCount = 0
        for command in project.commands {
            guard case let .stroke(existingStroke) = command else { continue }
            let (updatedTotal, didOverflow) = totalPointCount.addingReportingOverflow(existingStroke.points.count)
            guard !didOverflow else {
                return .totalStrokePointLimitExceeded(Int.max)
            }
            totalPointCount = updatedTotal
        }

        let (updatedTotal, didOverflow) = totalPointCount.addingReportingOverflow(stroke.points.count)
        guard !didOverflow, updatedTotal <= PaintingProject.maximumTotalStrokePointCount else {
            return .totalStrokePointLimitExceeded(didOverflow ? Int.max : updatedTotal)
        }
        return nil
    }

    private func cancelStrokePreviewAfterAdmissionFailure(
        token: StudioStrokePreviewToken
    ) {
        guard isFinalizingStrokePreview(token) else { return }
        let admissionFailure = error
        invalidateStrokePreview(token)
        do {
            try token.renderer.cancelStrokePreview(token.rendererToken)
            error = admissionFailure
        } catch {
            enterRendererRecovery(error)
        }
        refreshCapabilities()
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
        pendingStrokePreview = nil
        strokePreviewDrainTask?.cancel()
        strokePreviewDrainTask = nil
        strokePreviewDrainToken = nil
    }

    private func isCurrentStrokePreview(_ token: StudioStrokePreviewToken) -> Bool {
        strokePreviewState.token == token
    }

    private func isFinalizingStrokePreview(_ token: StudioStrokePreviewToken) -> Bool {
        guard case let .finalizing(current) = strokePreviewState else { return false }
        return current == token
    }

    private func enterRendererRecovery(_ recoveryCause: Error) {
        let recoveryError = StudioRendererRecoveryError.previewRestorationFailed(
            recoveryCause.localizedDescription
        )
        rendererRecoveryError = recoveryError
        rendererCheckpoints.removeAll()
        error = StudioFailure(message: recoveryError.localizedDescription)
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
            self.error = StudioFailure(message: error.localizedDescription)
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

    public func selectPaper(_ paper: PaperTexture) {
        let selectedLayerID = selectedLayerID
        performProjectEdit(
            { editor in editor.setPaper(paper) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
    }

    public func setBrushSize(_ size: Double) {
        guard size.isFinite else { return }
        brush.size = min(max(size, Self.brushSizeRange.lowerBound), Self.brushSizeRange.upperBound)
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
        let capturedFailureID = error?.id
        let capturedExportFailureID = currentPNGExportFailureID

        do {
            let snapshot = StudioPNGImageSnapshot(image: try renderer.makeCGImage())
            let worker = pngExportWorker
            try await Task.detached(priority: .userInitiated) {
                try await worker.export(snapshot, to: destinationURL)
            }.value
            guard latestPNGExportID == exportID,
                  error?.id == capturedFailureID
            else { return }
            if let capturedExportFailureID,
               capturedFailureID == capturedExportFailureID {
                error = nil
                currentPNGExportFailureID = nil
            }
        } catch {
            guard latestPNGExportID == exportID,
                  self.error?.id == capturedFailureID
            else { return }
            let failure = StudioFailure(
                message: "Could not export PNG to \(destinationURL.lastPathComponent): \(error.localizedDescription)"
            )
            self.error = failure
            currentPNGExportFailureID = failure.id
        }
    }

    public func dismissError() {
        error = nil
    }

    @discardableResult
    func replaceProjectFromDocument(_ replacement: PaintingProject) -> Bool {
        guard canModifyProject else { return false }
        guard replacement != project else { return true }

        do {
            try replacement.validate()
            rendererCheckpoints.removeAll()
            let candidateRenderer = try renderer.makeCandidate(project: replacement)
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
            self.error = StudioFailure(message: error.localizedDescription)
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
                let candidateRenderer = try renderer.makeCandidate(project: updatedProject)
                replaceRenderer(with: candidateRenderer)
            }
            publishSuccessfulEdit(
                editor: updatedEditor,
                project: updatedProject,
                selectedLayerID: nextSelection
            )
        } catch {
            self.error = StudioFailure(message: error.localizedDescription)
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
            let candidateRenderer = try renderer.makeCandidate(project: updatedProject)
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
            let failure = StudioFailure(message: error.localizedDescription)
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
                let candidateRenderer = try renderer.makeCandidate(project: updatedProject)
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
            self.error = StudioFailure(message: error.localizedDescription)
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
                && !isStrokePreviewFinalizing
                && project.layers.contains(where: { $0.id == selectedLayerID }),
            canUndo: canModifyProject && editor.canUndo,
            canRedo: canModifyProject && editor.canRedo
        )
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

    var token: StudioStrokePreviewToken? {
        switch self {
        case .idle: nil
        case let .active(token), let .finalizing(token): token
        }
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
    case strokeLayerUnavailable(UUID)
    case pngEncoding

    var errorDescription: String? {
        switch self {
        case let .strokeLayerUnavailable(identifier):
            "Stroke layer \(identifier.uuidString) is not part of this project."
        case .pngEncoding:
            "Image I/O could not encode the composited canvas."
        }
    }
}
