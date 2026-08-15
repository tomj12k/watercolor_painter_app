import Combine
import CoreGraphics
import Foundation
import MetalKit
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

public enum StudioActionRequest: Equatable, Sendable {
    case undo
    case redo
    case dryLayer(UUID)
    case exportPNG
}

@MainActor
public final class StudioModel: ObservableObject {
    public static let brushSizeRange = 1.0...300.0

    @Published public private(set) var project: PaintingProject
    @Published public var selectedLayerID: UUID {
        didSet { refreshCapabilities() }
    }
    @Published public var selectedTool: PaintTool
    @Published public var brush: BrushSettings
    @Published public var zoom: CGFloat
    @Published public var pan: CGSize
    @Published public private(set) var error: StudioFailure?
    @Published public private(set) var capabilities: StudioCapabilities
    @Published public private(set) var requestedAction: StudioActionRequest?

    public var onDocumentUpdate: ((PaintingProject) -> Void)?

    public var canAddLayer: Bool {
        project.layers.count < PaintingProject.maximumLayerCount
    }

    public var canDuplicateSelectedLayer: Bool {
        canAddLayer && selectedLayerIndex != nil
    }

    public var canDeleteSelectedLayer: Bool {
        project.layers.count > 1 && selectedLayerIndex != nil
    }

    public var canMoveSelectedLayerUp: Bool {
        guard let selectedLayerIndex else { return false }
        return selectedLayerIndex < project.layers.count - 1
    }

    public var canMoveSelectedLayerDown: Bool {
        guard let selectedLayerIndex else { return false }
        return selectedLayerIndex > 0
    }

    public var canMergeSelectedLayerDown: Bool {
        canMoveSelectedLayerDown
    }

    private let renderer: WatercolorRenderer
    private let canvasDelegate: CanvasRendererDelegate
    private var editor: ProjectEditor

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
        onDocumentUpdate: ((PaintingProject) -> Void)? = nil
    ) {
        editor = ProjectEditor(project: project)
        self.project = project
        selectedLayerID = project.layers[0].id
        selectedTool = .brush
        brush = .default
        zoom = 1
        pan = .zero
        error = nil
        capabilities = StudioCapabilities(canPaint: true, canUndo: false, canRedo: false)
        requestedAction = nil
        self.renderer = renderer
        canvasDelegate = CanvasRendererDelegate(renderer: renderer)
        self.onDocumentUpdate = onDocumentUpdate
        refreshCapabilities()
    }

    func completeStroke(_ stroke: StrokeCommand) {
        guard project.layers.contains(where: { $0.id == stroke.layerID }) else {
            error = StudioFailure(
                message: StudioCoordinationError.strokeLayerUnavailable(stroke.layerID).localizedDescription
            )
            return
        }

        do {
            try renderer.renderAndWait(stroke: stroke)
            editor.append(.stroke(stroke))
            publishEditorProject()
            error = nil
        } catch {
            let failure = StudioFailure(message: error.localizedDescription)
            try? renderer.replay(project: project)
            self.error = failure
        }
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
        performProjectEdit(
            { editor in try editor.moveLayer(id: layerID, to: selectedLayerIndex + 1) },
            selecting: { _ in layerID }
        )
    }

    public func moveSelectedLayerDown() {
        guard let selectedLayerIndex, canMoveSelectedLayerDown else { return }
        let layerID = selectedLayerID
        performProjectEdit(
            { editor in try editor.moveLayer(id: layerID, to: selectedLayerIndex - 1) },
            selecting: { _ in layerID }
        )
    }

    public func renameLayer(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let selectedLayerID = selectedLayerID
        performProjectEdit(
            { editor in try editor.renameLayer(id: id, to: trimmedName) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
    }

    public func setLayerVisibility(id: UUID, isVisible: Bool) {
        let selectedLayerID = selectedLayerID
        performProjectEdit(
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
        performProjectEdit(
            { editor in try editor.setLayerOpacity(id: id, opacity: clampedOpacity) },
            selecting: { project in
                project.layers.first(where: { $0.id == selectedLayerID })?.id
            }
        )
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

    public func requestUndo() {
        requestedAction = .undo
    }

    public func requestRedo() {
        requestedAction = .redo
    }

    public func requestDrySelectedLayer() {
        guard selectedLayerIndex != nil else { return }
        requestedAction = .dryLayer(selectedLayerID)
    }

    public func requestPNGExport() {
        requestedAction = .exportPNG
    }

    public func dismissError() {
        error = nil
    }

    public func configureCanvas(_ view: MTKView) {
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

    private func performProjectEdit(
        _ edit: (inout ProjectEditor) throws -> Void,
        selecting selection: (PaintingProject) -> UUID?
    ) {
        let previousProject = project
        var updatedEditor = editor

        do {
            try edit(&updatedEditor)
            let updatedProject = updatedEditor.project
            guard updatedProject != previousProject else { return }
            try renderer.replay(project: updatedProject)
            editor = updatedEditor
            project = updatedProject
            selectedLayerID = selection(updatedProject) ?? selectedLayerID
            refreshCapabilities()
            onDocumentUpdate?(project)
            error = nil
        } catch {
            let failure = StudioFailure(message: error.localizedDescription)
            try? renderer.replay(project: previousProject)
            self.error = failure
        }
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
            canPaint: project.layers.contains(where: { $0.id == selectedLayerID }),
            canUndo: editor.canUndo,
            canRedo: editor.canRedo
        )
    }
}

@MainActor
private final class CanvasRendererDelegate: NSObject, MTKViewDelegate {
    private let renderer: WatercolorRenderer

    init(renderer: WatercolorRenderer) {
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

    var errorDescription: String? {
        switch self {
        case let .strokeLayerUnavailable(identifier):
            "Stroke layer \(identifier.uuidString) is not part of this project."
        }
    }
}
