import AppKit
import SwiftUI
import WatercolorCore

struct BrushInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioSectionTitle(title: "Brush")

            Picker("Style", selection: styleBinding) {
                ForEach(WatercolorStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .help("Choose how pigment and water behave")

            Picker("Shape", selection: brushBinding(\.shape)) {
                ForEach(BrushShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }

            Picker("Hair", selection: brushBinding(\.hair)) {
                ForEach(BrushHair.allCases, id: \.self) { hair in
                    Text(hair.displayName).tag(hair)
                }
            }

            Picker("Texture", selection: brushBinding(\.texture)) {
                ForEach(BrushTexture.allCases, id: \.self) { texture in
                    Text(texture.displayName).tag(texture)
                }
            }

            Divider()
                .overlay(StudioPalette.graphite.opacity(0.24))

            StudioSectionTitle(title: "Color")

            ColorPicker("Pigment", selection: colorBinding, supportsOpacity: false)
                .help("Open the native color wheel")

            HStack(spacing: 7) {
                ForEach(Self.swatches, id: \.name) { swatch in
                    Button {
                        model.brush.color = swatch.color
                    } label: {
                        Circle()
                            .fill(swatch.swiftUIColor)
                            .frame(width: 19, height: 19)
                            .overlay {
                                Circle().stroke(StudioPalette.graphite.opacity(0.55), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.borderless)
                    .help(swatch.name)
                    .accessibilityLabel("Use \(swatch.name) pigment")
                }
            }

            Divider()
                .overlay(StudioPalette.graphite.opacity(0.24))

            NumericControl(
                title: "Size",
                value: Binding(get: { model.brush.size }, set: { model.setBrushSize($0) }),
                range: StudioModel.brushSizeRange,
                step: 1,
                display: { "\(Int($0.rounded())) pt" }
            )

            NumericControl(
                title: "Opacity",
                value: brushBinding(\.opacity),
                range: 0...1,
                step: 0.01,
                display: { Self.percent($0) }
            )

            NumericControl(
                title: "Flow",
                value: brushBinding(\.flow),
                range: 0...1,
                step: 0.01,
                display: { Self.percent($0) }
            )

            NumericControl(
                title: "Water",
                value: brushBinding(\.water),
                range: 0...1,
                step: 0.01,
                display: { Self.percent($0) }
            )

            NumericControl(
                title: "Granulation",
                value: brushBinding(\.granulation),
                range: 0...1,
                step: 0.01,
                display: { Self.percent($0) }
            )

            NumericControl(
                title: "Edge bloom",
                value: brushBinding(\.edgeBloom),
                range: 0...1,
                step: 0.01,
                display: { Self.percent($0) }
            )
        }
        .font(.system(size: 12))
        .tint(StudioPalette.cobalt)
    }

    private var styleBinding: Binding<WatercolorStyle> {
        Binding(
            get: { model.brush.style },
            set: { model.selectStyle($0) }
        )
    }

    private func brushBinding<Value>(_ keyPath: WritableKeyPath<BrushSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.brush[keyPath: keyPath] },
            set: { model.brush[keyPath: keyPath] = $0 }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: model.brush.color.red,
                    green: model.brush.color.green,
                    blue: model.brush.color.blue,
                    opacity: model.brush.color.alpha
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.brush.color = PaintColor(
                    red: Double(converted.redComponent),
                    green: Double(converted.greenComponent),
                    blue: Double(converted.blueComponent),
                    alpha: Double(converted.alphaComponent)
                )
            }
        )
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static let swatches: [(name: String, color: PaintColor, swiftUIColor: Color)] = [
        ("Carbon", PaintColor(red: 0.11, green: 0.10, blue: 0.09), StudioPalette.carbon),
        ("Cobalt", PaintColor(red: 0.12, green: 0.32, blue: 0.48), Color(red: 0.12, green: 0.32, blue: 0.48)),
        ("Pigment red", PaintColor(red: 0.68, green: 0.19, blue: 0.12), Color(red: 0.68, green: 0.19, blue: 0.12)),
        ("Ochre", PaintColor(red: 0.72, green: 0.48, blue: 0.13), Color(red: 0.72, green: 0.48, blue: 0.13)),
        ("Sap green", PaintColor(red: 0.20, green: 0.39, blue: 0.20), Color(red: 0.20, green: 0.39, blue: 0.20))
    ]
}

private struct NumericControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .foregroundStyle(StudioPalette.graphite)
                Spacer()
                Text(display(value))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(StudioPalette.fiber)
            }

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(display(value))

                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Adjust \(title.lowercased())")
                    .accessibilityValue(display(value))
            }
        }
    }
}

private extension WatercolorStyle {
    var displayName: String {
        switch self {
        case .transparentWash: "Transparent wash"
        case .wetOnWet: "Wet on wet"
        case .dryBrush: "Dry brush"
        case .glazing: "Glazing"
        case .bloom: "Bloom"
        }
    }
}

private extension BrushShape {
    var displayName: String { rawValue.capitalized }
}

private extension BrushHair {
    var displayName: String { rawValue.capitalized }
}

private extension BrushTexture {
    var displayName: String { rawValue.capitalized }
}
