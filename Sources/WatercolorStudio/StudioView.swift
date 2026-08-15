import SwiftUI
import WatercolorCore

enum StudioPalette {
    static let carbon = Color(red: 28 / 255, green: 27 / 255, blue: 25 / 255)
    static let easel = Color(red: 41 / 255, green: 39 / 255, blue: 36 / 255)
    static let fiber = Color(red: 245 / 255, green: 240 / 255, blue: 230 / 255)
    static let graphite = Color(red: 184 / 255, green: 178 / 255, blue: 167 / 255)
    static let cobalt = Color(red: 91 / 255, green: 127 / 255, blue: 147 / 255)
    static let pigment = Color(red: 201 / 255, green: 104 / 255, blue: 75 / 255)
}

struct StudioSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold, design: .serif))
            .foregroundStyle(StudioPalette.fiber)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct StudioView: View {
    @ObservedObject private var model: StudioModel

    public init(model: StudioModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            ToolRail(model: model)
                .frame(width: 52)

            Rectangle()
                .fill(StudioPalette.graphite.opacity(0.22))
                .frame(width: 1)

            paperStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(StudioPalette.graphite.opacity(0.22))
                .frame(width: 1)

            inspector
                .frame(width: 292)
        }
        .background(StudioPalette.carbon)
        .frame(minWidth: 1_050, minHeight: 680)
        .focusedSceneValue(\.studioModel, model)
        .toolbar { studioToolbar }
    }

    private var paperStage: some View {
        GeometryReader { geometry in
            let canvasSize = CGSize(
                width: model.project.canvas.width,
                height: model.project.canvas.height
            )
            let transform = CanvasTransform(
                viewSize: geometry.size,
                canvasSize: canvasSize,
                zoom: model.zoom,
                pan: model.pan
            )
            let paperRect = transform.paperRect

            ZStack(alignment: .bottomLeading) {
                StudioPalette.easel

                MetalCanvasView(model: model)

                Rectangle()
                    .stroke(
                        StudioPalette.cobalt.opacity(0.28 + model.canvasWetness * 0.62),
                        style: StrokeStyle(lineWidth: 1 + model.canvasWetness, dash: [1.5, 2.5])
                    )
                    .frame(width: max(paperRect.width, 0), height: max(paperRect.height, 0))
                    .position(
                        x: paperRect.midX,
                        y: geometry.size.height - paperRect.midY
                    )
                    .shadow(color: StudioPalette.cobalt.opacity(0.28), radius: 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Image(systemName: "drop.fill")
                    Text(activityLabel)
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioPalette.fiber)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(StudioPalette.carbon.opacity(0.88))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(StudioPalette.cobalt)
                        .frame(width: 2)
                }
                .padding(12)
                .accessibilityLabel("Canvas activity")
                .accessibilityValue(activityLabel)
            }
            .clipped()
        }
    }

    private var activityLabel: String {
        "Canvas wetness \(Int((model.canvasWetness * 100).rounded()))%"
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    BrushInspector(model: model)

                    Divider()
                        .overlay(StudioPalette.graphite.opacity(0.28))

                    PaperInspector(model: model)
                }
                .padding(14)
            }
            .frame(maxHeight: 410)

            Divider()
                .overlay(StudioPalette.graphite.opacity(0.32))

            LayersInspector(model: model)
                .frame(maxHeight: .infinity)
        }
        .background(StudioPalette.carbon)
        .foregroundStyle(StudioPalette.fiber)
    }

    @ToolbarContentBuilder
    private var studioToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.requestUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.capabilities.canUndo)
            .help("Undo (Command-Z)")

            Button(action: model.requestRedo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.capabilities.canRedo)
            .help("Redo (Shift-Command-Z)")
        }

        ToolbarItemGroup(placement: .principal) {
            Button {
                model.zoom = max(model.zoom / 1.2, 0.1)
            } label: {
                Label("Zoom out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(Int((model.zoom * 100).rounded()))%")
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 46)
                .accessibilityLabel("Zoom")

            Button {
                model.zoom = min(model.zoom * 1.2, 16)
            } label: {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Button(action: model.fitCanvas) {
                Label("Fit canvas", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit canvas (Command-0)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.requestDrySelectedLayer) {
                Label("Dry layer", systemImage: "wind")
            }
            .disabled(!model.capabilities.canPaint)
            .help("Dry selected layer")

            Button(action: model.requestPNGExport) {
                Label("Export PNG", systemImage: "square.and.arrow.up")
            }
            .help("Export PNG")
        }
    }

}
