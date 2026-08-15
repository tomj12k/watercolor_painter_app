import Combine
import CoreGraphics
import Foundation
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

@MainActor
public final class StudioModel: ObservableObject {
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

    public let renderer: WatercolorRenderer
    public var onDocumentUpdate: ((PaintingProject) -> Void)?

    private var editor: ProjectEditor

    public convenience init(
        project: PaintingProject,
        onDocumentUpdate: ((PaintingProject) -> Void)? = nil
    ) throws {
        let renderer = try WatercolorRenderer(project: project)
        self.init(project: project, renderer: renderer, onDocumentUpdate: onDocumentUpdate)
    }

    public init(
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
        self.renderer = renderer
        self.onDocumentUpdate = onDocumentUpdate
        refreshCapabilities()
    }

    public func completeStroke(_ stroke: StrokeCommand) {
        do {
            try renderer.render(stroke: stroke)
            editor.append(.stroke(stroke))
            publishEditorProject()
            error = nil
        } catch {
            self.error = StudioFailure(message: error.localizedDescription)
        }
    }

    private func publishEditorProject() {
        project = editor.project
        refreshCapabilities()
        onDocumentUpdate?(project)
    }

    private func refreshCapabilities() {
        capabilities = StudioCapabilities(
            canPaint: project.layers.contains(where: { $0.id == selectedLayerID }),
            canUndo: editor.canUndo,
            canRedo: editor.canRedo
        )
    }
}
