import Foundation
import SwiftUI
import WatercolorCore

struct StudioPaletteSRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    private static func linearized(_ value: Double) -> Double {
        let value = value.isFinite ? min(max(value, 0), 1) : 0
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }
}

enum StudioPalette {
    static let carbonSRGB = StudioPaletteSRGB(red: 28 / 255, green: 27 / 255, blue: 25 / 255)
    static let easelSRGB = StudioPaletteSRGB(red: 41 / 255, green: 39 / 255, blue: 36 / 255)
    static let fiberSRGB = StudioPaletteSRGB(red: 245 / 255, green: 240 / 255, blue: 230 / 255)
    static let graphiteSRGB = StudioPaletteSRGB(red: 184 / 255, green: 178 / 255, blue: 167 / 255)
    static let cobaltSRGB = StudioPaletteSRGB(red: 91 / 255, green: 127 / 255, blue: 147 / 255)
    static let pigmentSRGB = StudioPaletteSRGB(red: 201 / 255, green: 104 / 255, blue: 75 / 255)

    static let carbon = carbonSRGB.swiftUIColor
    static let easel = easelSRGB.swiftUIColor
    static let fiber = fiberSRGB.swiftUIColor
    static let graphite = graphiteSRGB.swiftUIColor
    static let cobalt = cobaltSRGB.swiftUIColor
    static let pigment = pigmentSRGB.swiftUIColor

    static func contrastRatio(
        foreground: StudioPaletteSRGB,
        background: StudioPaletteSRGB
    ) -> Double {
        let lighter = max(foreground.relativeLuminance, background.relativeLuminance)
        let darker = min(foreground.relativeLuminance, background.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
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

                if model.rendererRecoveryError != nil {
                    recoveryBanner
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

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

                VStack(alignment: .leading, spacing: 6) {
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
                    .accessibilityLabel("Canvas activity")
                    .accessibilityValue(activityLabel)

                    if model.isApplyingSurfaceChange {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing the paper surface…")
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
                        .accessibilityLabel("Paper surface")
                        .accessibilityValue("Preparing the paper surface")
                    }

                    if let capacityWarning = model.capacityWarning {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.needle")
                            Text(capacityWarning)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioPalette.fiber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(StudioPalette.carbon.opacity(0.88))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(StudioPalette.pigment)
                                .frame(width: 2)
                        }
                        .accessibilityLabel("Painting capacity")
                        .accessibilityValue(capacityWarning)
                    }
                }
                .padding(12)
            }
            .clipped()
        }
    }

    private var activityLabel: String {
        "Canvas wetness \(Int((model.canvasWetness * 100).rounded()))%"
    }

    private var recoveryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text("Painting is paused after a renderer problem. Your work so far is safe.")
            Button("Try Again", action: model.retryRendererRecovery)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(StudioPalette.cobalt)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(StudioPalette.fiber)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(StudioPalette.carbon.opacity(0.94))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StudioPalette.pigment)
                .frame(width: 2)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Renderer recovery")
        .accessibilityHint("Painting is paused. Try Again rebuilds the renderer from your saved work.")
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
            Button(action: model.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.capabilities.canUndo)
            .help("Undo (Command-Z)")

            Button(action: model.redo) {
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
            Button(action: model.drySelectedLayer) {
                Label("Dry layer", systemImage: "wind")
            }
            .disabled(!model.canModifyProject || !model.capabilities.canPaint)
            .help("Dry selected layer")

            Button {
                StudioPNGExportPanel.present(for: model)
            } label: {
                Label("Export PNG", systemImage: "square.and.arrow.up")
            }
            .help("Export PNG")
        }
    }

}
