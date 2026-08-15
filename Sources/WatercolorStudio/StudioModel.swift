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

    public var onDocumentUpdate: ((PaintingProject) -> Void)?

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
