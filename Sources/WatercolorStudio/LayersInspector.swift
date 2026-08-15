import SwiftUI
import WatercolorCore

struct LayersInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 10) {
            StudioSectionTitle(title: "Layers")
                .padding(.horizontal, 14)
                .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.project.layers.reversed())) { layer in
                        LayerRow(model: model, layerID: layer.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            }

            layerActions
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .font(.system(size: 12))
        .tint(StudioPalette.cobalt)
    }

    private var layerActions: some View {
        HStack(spacing: 2) {
            layerAction("Add layer", systemImage: "plus", action: model.addLayer)
                .disabled(!model.canAddLayer)

            layerAction("Duplicate layer", systemImage: "square.on.square", action: model.duplicateSelectedLayer)
                .disabled(!model.canDuplicateSelectedLayer)

            layerAction("Delete layer", systemImage: "trash", action: model.deleteSelectedLayer)
                .disabled(!model.canDeleteSelectedLayer)

            Divider().frame(height: 18)

            layerAction("Move layer up", systemImage: "chevron.up", action: model.moveSelectedLayerUp)
                .disabled(!model.canMoveSelectedLayerUp)

            layerAction("Move layer down", systemImage: "chevron.down", action: model.moveSelectedLayerDown)
                .disabled(!model.canMoveSelectedLayerDown)

            layerAction("Merge layer down", systemImage: "arrow.down", action: model.mergeSelectedLayerDown)
                .disabled(!model.canMergeSelectedLayerDown)

            layerAction("Clear layer", systemImage: "xmark.rectangle", action: model.clearSelectedLayer)
                .disabled(!model.capabilities.canPaint)
        }
        .frame(maxWidth: .infinity)
    }

    private func layerAction(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 25, height: 24)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct LayerRow: View {
    @ObservedObject var model: StudioModel
    let layerID: UUID

    @State private var draftName: String = ""
    @FocusState private var isEditingName: Bool

    private var layer: PaintLayer? {
        model.project.layers.first(where: { $0.id == layerID })
    }

    private var isSelected: Bool {
        model.selectedLayerID == layerID
    }

    var body: some View {
        if let layer {
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Button {
                        model.selectedLayerID = layerID
                    } label: {
                        Image(systemName: isSelected ? "record.circle" : "circle")
                            .foregroundStyle(isSelected ? StudioPalette.fiber : StudioPalette.graphite)
                    }
                    .buttonStyle(.borderless)
                    .help(isSelected ? "Selected layer" : "Select \(layer.name)")
                    .accessibilityLabel("Select \(layer.name)")
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")

                    Button {
                        model.setLayerVisibility(id: layerID, isVisible: !layer.isVisible)
                    } label: {
                        Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                            .foregroundStyle(layer.isVisible ? StudioPalette.fiber : StudioPalette.graphite)
                    }
                    .buttonStyle(.borderless)
                    .help(layer.isVisible ? "Hide layer" : "Show layer")
                    .accessibilityLabel("Layer visibility")
                    .accessibilityValue(layer.isVisible ? "Visible" : "Hidden")

                    TextField("Layer name", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($isEditingName)
                        .onTapGesture { model.selectedLayerID = layerID }
                        .onSubmit(commitName)
                        .accessibilityLabel("Layer name")
                }

                HStack(spacing: 7) {
                    Text("Opacity")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.graphite)

                    Slider(value: opacityBinding, in: 0...1, step: 0.01)
                        .accessibilityLabel("\(layer.name) opacity")

                    Text("\(Int((layer.opacity * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isSelected ? StudioPalette.cobalt.opacity(0.22) : StudioPalette.easel.opacity(0.58))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? StudioPalette.cobalt : Color.clear)
                    .frame(width: 2)
            }
            .onAppear { draftName = layer.name }
            .onChange(of: layer.name) { _, newName in
                if !isEditingName { draftName = newName }
            }
            .onChange(of: isEditingName) { wasEditing, isEditing in
                if wasEditing, !isEditing { commitName() }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { layer?.opacity ?? 1 },
            set: { model.setLayerOpacity(id: layerID, opacity: $0) }
        )
    }

    private func commitName() {
        guard let layer else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftName = layer.name
        } else {
            draftName = trimmed
            model.renameLayer(id: layerID, to: trimmed)
        }
    }
}
