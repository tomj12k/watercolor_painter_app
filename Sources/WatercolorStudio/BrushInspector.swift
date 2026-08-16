import AppKit
import SwiftUI
import WatercolorCore

struct BrushAccessibilityPresentation: Equatable, Sendable {
    let label: String
    let help: String
}

struct BrushNumericPresentation: Equatable, Sendable {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let accessibility: BrushAccessibilityPresentation
}

enum BrushInspectorPresentation {
    static let sectionTitles = ["Identity", "Color", "Paint", "Dynamics"]

    static let identityAccessibility = [
        BrushAccessibilityPresentation(
            label: "Brush style",
            help: "Choose how pigment and water behave on the paper."
        ),
        BrushAccessibilityPresentation(
            label: "Brush shape",
            help: "Choose the footprint the brush leaves as it moves."
        ),
        BrushAccessibilityPresentation(
            label: "Brush hair",
            help: "Choose how the brush carries and releases pigment and water."
        ),
        BrushAccessibilityPresentation(
            label: "Brush texture",
            help: "Choose the paper pattern visible through the stroke."
        )
    ]

    static let colorAccessibility = [
        BrushAccessibilityPresentation(
            label: "Pigment color",
            help: "Open the native color wheel to choose a pigment."
        )
    ]

    static let paintAccessibility = [
        BrushAccessibilityPresentation(
            label: "Brush size",
            help: "Set the width of the brush in points."
        ),
        BrushAccessibilityPresentation(
            label: "Paint opacity",
            help: "Set how transparent the pigment appears."
        ),
        BrushAccessibilityPresentation(
            label: "Paint flow",
            help: "Set how quickly pigment leaves the brush."
        ),
        BrushAccessibilityPresentation(
            label: "Paint water",
            help: "Set how much water the brush carries."
        ),
        BrushAccessibilityPresentation(
            label: "Paint granulation",
            help: "Set how strongly pigment settles into the paper."
        ),
        BrushAccessibilityPresentation(
            label: "Paint edge bloom",
            help: "Set how strongly pigment gathers along wet edges."
        )
    ]

    static let dynamics = [
        BrushNumericPresentation(
            title: "Spacing",
            range: 0.08...0.60,
            step: 0.01,
            accessibility: BrushAccessibilityPresentation(
                label: "Brush spacing",
                help: "Set the distance between brush marks. Lower spacing makes a denser stroke."
            )
        ),
        BrushNumericPresentation(
            title: "Rotation",
            range: -180...180,
            step: 1,
            accessibility: BrushAccessibilityPresentation(
                label: "Brush rotation",
                help: "Rotate the brush footprint relative to the stroke direction."
            )
        ),
        BrushNumericPresentation(
            title: "Bristle",
            range: 0...1,
            step: 0.01,
            accessibility: BrushAccessibilityPresentation(
                label: "Bristle strength",
                help: "Blend from a solid brush footprint to the selected hair pattern."
            )
        ),
        BrushNumericPresentation(
            title: "Texture strength",
            range: 0...1,
            step: 0.01,
            accessibility: BrushAccessibilityPresentation(
                label: "Texture strength",
                help: "Blend from smooth coverage to the selected paper texture."
            )
        )
    ]

    static let recipeAccessibility = BrushAccessibilityPresentation(
        label: "Brush recipe",
        help: "Summarizes the selected shape, hair, texture, and watercolor style."
    )

    static let resetDynamicsAccessibility = BrushAccessibilityPresentation(
        label: "Reset brush dynamics",
        help: "Restore spacing, rotation, bristle, and texture strength to their defaults."
    )

    static let resetDynamicsLabelColor = StudioPalette.fiberSRGB

    static func description(for style: WatercolorStyle) -> String {
        switch style {
        case .transparentWash:
            "An even translucent wash that lets the paper glow through."
        case .wetOnWet:
            "A fluid wash that spreads softly into damp color."
        case .dryBrush:
            "A low-water broken stroke that leaves paper showing."
        case .glazing:
            "A thin controlled layer for building color gradually."
        case .bloom:
            "A wet bloom that gathers pigment along expanding edges."
        }
    }

    static func description(for shape: BrushShape) -> String {
        switch shape {
        case .round:
            "A versatile round point with a soft circular footprint."
        case .flat:
            "A broad flat chisel that leaves a crisp long edge."
        case .filbert:
            "A rounded filbert oval for broad marks with soft ends."
        case .fan:
            "A splayed fan that separates into five tapered fingers."
        case .rigger:
            "A long narrow rigger for continuous fine lines."
        }
    }

    static func description(for hair: BrushHair) -> String {
        switch hair {
        case .sable:
            "Balanced sable hair that carries pigment and water smoothly."
        case .squirrel:
            "Soft squirrel hair with a generous, gentle water release."
        case .synthetic:
            "Springy synthetic hair with a crisp pigment-rich release."
        case .bristle:
            "Stiff bristles that leave separated, broken paint lanes."
        case .mop:
            "A broad soft mop that releases a generous load of water."
        }
    }

    static func description(for texture: BrushTexture) -> String {
        switch texture {
        case .smooth:
            "Smooth coverage with an even response across the paper."
        case .granulating:
            "Granulating pigment that settles into the paper valleys."
        case .dry:
            "A dry texture with connected skips of exposed paper."
        case .mottled:
            "A mottled texture with broad natural pigment variation."
        case .salt:
            "A salt texture with sparse pale centers and ringed blooms."
        }
    }

    static func recipe(for brush: BrushSettings) -> String {
        "\(recipeFragment(for: brush.shape)) + \(recipeFragment(for: brush.hair)) · \(recipeFragment(for: brush.texture)) · \(recipeFragment(for: brush.style))"
    }

    private static func recipeFragment(for style: WatercolorStyle) -> String {
        switch style {
        case .transparentWash: "Light wash"
        case .wetOnWet: "Wet spread"
        case .dryBrush: "Dry brush"
        case .glazing: "Glaze"
        case .bloom: "Bloom edge"
        }
    }

    private static func recipeFragment(for shape: BrushShape) -> String {
        switch shape {
        case .round: "Round"
        case .flat: "Flat"
        case .filbert: "Filbert"
        case .fan: "Fan"
        case .rigger: "Rigger"
        }
    }

    private static func recipeFragment(for hair: BrushHair) -> String {
        switch hair {
        case .sable: "sable"
        case .squirrel: "squirrel"
        case .synthetic: "synthetic"
        case .bristle: "bristle"
        case .mop: "mop"
        }
    }

    private static func recipeFragment(for texture: BrushTexture) -> String {
        switch texture {
        case .smooth: "Smooth"
        case .granulating: "Granulating"
        case .dry: "Dry skips"
        case .mottled: "Mottled"
        case .salt: "Salt blooms"
        }
    }
}

struct BrushInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identitySection
            sectionDivider
            colorSection
            sectionDivider
            paintSection
            sectionDivider
            dynamicsSection
        }
        .font(.system(size: 12))
        .tint(StudioPalette.cobalt)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioSectionTitle(title: BrushInspectorPresentation.sectionTitles[0])

            Picker("Style", selection: styleBinding) {
                ForEach(WatercolorStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .help(BrushInspectorPresentation.description(for: model.brush.style))
            .accessibilityLabel(BrushInspectorPresentation.identityAccessibility[0].label)
            .accessibilityValue(model.brush.style.displayName)
            .accessibilityHint(BrushInspectorPresentation.identityAccessibility[0].help)

            Picker("Shape", selection: brushBinding(\.shape)) {
                ForEach(BrushShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .help(BrushInspectorPresentation.description(for: model.brush.shape))
            .accessibilityLabel(BrushInspectorPresentation.identityAccessibility[1].label)
            .accessibilityValue(model.brush.shape.displayName)
            .accessibilityHint(BrushInspectorPresentation.identityAccessibility[1].help)

            Picker("Hair", selection: brushBinding(\.hair)) {
                ForEach(BrushHair.allCases, id: \.self) { hair in
                    Text(hair.displayName).tag(hair)
                }
            }
            .help(BrushInspectorPresentation.description(for: model.brush.hair))
            .accessibilityLabel(BrushInspectorPresentation.identityAccessibility[2].label)
            .accessibilityValue(model.brush.hair.displayName)
            .accessibilityHint(BrushInspectorPresentation.identityAccessibility[2].help)

            Picker("Texture", selection: brushBinding(\.texture)) {
                ForEach(BrushTexture.allCases, id: \.self) { texture in
                    Text(texture.displayName).tag(texture)
                }
            }
            .help(BrushInspectorPresentation.description(for: model.brush.texture))
            .accessibilityLabel(BrushInspectorPresentation.identityAccessibility[3].label)
            .accessibilityValue(model.brush.texture.displayName)
            .accessibilityHint(BrushInspectorPresentation.identityAccessibility[3].help)

            HStack(spacing: 7) {
                Rectangle()
                    .fill(StudioPalette.pigment)
                    .frame(width: 2, height: 15)
                    .accessibilityHidden(true)
                Text(BrushInspectorPresentation.recipe(for: model.brush))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(StudioPalette.fiber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .help(BrushInspectorPresentation.recipeAccessibility.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BrushInspectorPresentation.recipeAccessibility.label)
            .accessibilityValue(BrushInspectorPresentation.recipe(for: model.brush))
            .accessibilityHint(BrushInspectorPresentation.recipeAccessibility.help)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioSectionTitle(title: BrushInspectorPresentation.sectionTitles[1])

            ColorPicker("Pigment", selection: colorBinding, supportsOpacity: false)
                .help(BrushInspectorPresentation.colorAccessibility[0].help)
                .accessibilityLabel(BrushInspectorPresentation.colorAccessibility[0].label)
                .accessibilityValue(colorAccessibilityValue)

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
                    .help("Use \(swatch.name) pigment")
                    .accessibilityLabel("Use \(swatch.name) pigment")
                    .accessibilityValue("Color swatch")
                }
            }

            if !model.recentColors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.graphite)
                    HStack(spacing: 7) {
                        ForEach(Array(model.recentColors.enumerated()), id: \.offset) { index, color in
                            Button {
                                model.brush.color = color
                            } label: {
                                Circle()
                                    .fill(Self.swiftUIColor(for: color))
                                    .frame(width: 19, height: 19)
                                    .overlay {
                                        Circle().stroke(StudioPalette.graphite.opacity(0.55), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.borderless)
                            .help("Use recent pigment \(index + 1)")
                            .accessibilityLabel("Use recent pigment \(index + 1)")
                            .accessibilityValue("Recent color")
                        }
                    }
                }
            }
        }
    }

    private var paintSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            StudioSectionTitle(title: BrushInspectorPresentation.sectionTitles[2])

            NumericControl(
                presentation: BrushNumericPresentation(
                    title: "Size",
                    range: StudioModel.brushSizeRange,
                    step: 1,
                    accessibility: BrushInspectorPresentation.paintAccessibility[0]
                ),
                value: Binding(get: { model.brush.size }, set: { model.setBrushSize($0) }),
                display: { "\(Int($0.rounded())) pt" }
            )

            NumericControl(
                presentation: paintPresentation(at: 1, title: "Opacity"),
                value: brushBinding(\.opacity),
                display: Self.percent
            )
            NumericControl(
                presentation: paintPresentation(at: 2, title: "Flow"),
                value: brushBinding(\.flow),
                display: Self.percent
            )
            NumericControl(
                presentation: paintPresentation(at: 3, title: "Water"),
                value: brushBinding(\.water),
                display: Self.percent
            )
            NumericControl(
                presentation: paintPresentation(at: 4, title: "Granulation"),
                value: brushBinding(\.granulation),
                display: Self.percent
            )
            NumericControl(
                presentation: paintPresentation(at: 5, title: "Edge bloom"),
                value: brushBinding(\.edgeBloom),
                display: Self.percent
            )
        }
    }

    private var dynamicsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            StudioSectionTitle(title: BrushInspectorPresentation.sectionTitles[3])

            NumericControl(
                presentation: BrushInspectorPresentation.dynamics[0],
                value: Binding(get: { model.brush.spacing }, set: { model.setBrushSpacing($0) }),
                display: Self.percent
            )
            NumericControl(
                presentation: BrushInspectorPresentation.dynamics[1],
                value: Binding(get: { model.brush.rotation }, set: { model.setBrushRotation($0) }),
                display: { "\(Int($0.rounded()))°" }
            )
            NumericControl(
                presentation: BrushInspectorPresentation.dynamics[2],
                value: Binding(
                    get: { model.brush.bristleStrength },
                    set: { model.setBristleStrength($0) }
                ),
                display: Self.percent
            )
            NumericControl(
                presentation: BrushInspectorPresentation.dynamics[3],
                value: Binding(
                    get: { model.brush.textureStrength },
                    set: { model.setTextureStrength($0) }
                ),
                display: Self.percent
            )

            Button(action: model.resetBrushDynamics) {
                Text("Reset dynamics")
                    .foregroundStyle(
                        BrushInspectorPresentation.resetDynamicsLabelColor.swiftUIColor
                    )
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(StudioPalette.cobalt)
                .help(BrushInspectorPresentation.resetDynamicsAccessibility.help)
                .accessibilityLabel(BrushInspectorPresentation.resetDynamicsAccessibility.label)
                .accessibilityValue("Defaults: 18% spacing, 0° rotation, 50% bristle, 50% texture strength")
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(StudioPalette.graphite.opacity(0.24))
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
                let color = model.brush.color.convertedToSRGB()
                return Color(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    opacity: color.alpha
                )
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.selectPickerColor(PaintColor.fromSRGB(
                    red: Double(converted.redComponent),
                    green: Double(converted.greenComponent),
                    blue: Double(converted.blueComponent),
                    alpha: Double(converted.alphaComponent)
                ))
            }
        )
    }

    private var colorAccessibilityValue: String {
        let color = model.brush.color.convertedToSRGB()
        return "Red \(Int((color.red * 100).rounded()))%, green \(Int((color.green * 100).rounded()))%, blue \(Int((color.blue * 100).rounded()))%"
    }

    private func paintPresentation(at index: Int, title: String) -> BrushNumericPresentation {
        BrushNumericPresentation(
            title: title,
            range: 0...1,
            step: 0.01,
            accessibility: BrushInspectorPresentation.paintAccessibility[index]
        )
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func swiftUIColor(for color: PaintColor) -> Color {
        let color = color.convertedToSRGB()
        return Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    private static let swatches: [(name: String, color: PaintColor, swiftUIColor: Color)] = [
        ("Carbon", .fromSRGB(red: 0.11, green: 0.10, blue: 0.09), StudioPalette.carbon),
        ("Cobalt", .fromSRGB(red: 0.12, green: 0.32, blue: 0.48), Color(red: 0.12, green: 0.32, blue: 0.48)),
        ("Pigment red", .fromSRGB(red: 0.68, green: 0.19, blue: 0.12), Color(red: 0.68, green: 0.19, blue: 0.12)),
        ("Ochre", .fromSRGB(red: 0.72, green: 0.48, blue: 0.13), Color(red: 0.72, green: 0.48, blue: 0.13)),
        ("Sap green", .fromSRGB(red: 0.20, green: 0.39, blue: 0.20), Color(red: 0.20, green: 0.39, blue: 0.20))
    ]
}

private struct NumericControl: View {
    let presentation: BrushNumericPresentation
    @Binding var value: Double
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(presentation.title)
                    .foregroundStyle(StudioPalette.graphite)
                Spacer()
                Text(display(value))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(StudioPalette.fiber)
            }

            HStack(spacing: 8) {
                Slider(
                    value: $value,
                    in: presentation.range,
                    step: presentation.step
                )
                .help(presentation.accessibility.help)
                .accessibilityLabel(presentation.accessibility.label)
                .accessibilityValue(display(value))

                Stepper(
                    presentation.title,
                    value: $value,
                    in: presentation.range,
                    step: presentation.step
                )
                .labelsHidden()
                .fixedSize()
                .help(presentation.accessibility.help)
                .accessibilityLabel("Adjust \(presentation.accessibility.label.lowercased())")
                .accessibilityValue(display(value))
            }
        }
    }
}

extension WatercolorStyle {
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

extension BrushShape {
    var displayName: String {
        switch self {
        case .round: "Round"
        case .flat: "Flat"
        case .filbert: "Filbert"
        case .fan: "Fan"
        case .rigger: "Rigger"
        }
    }
}

extension BrushHair {
    var displayName: String {
        switch self {
        case .sable: "Sable"
        case .squirrel: "Squirrel"
        case .synthetic: "Synthetic"
        case .bristle: "Bristle"
        case .mop: "Mop"
        }
    }
}

extension BrushTexture {
    var displayName: String {
        switch self {
        case .smooth: "Smooth"
        case .granulating: "Granulating"
        case .dry: "Dry"
        case .mottled: "Mottled"
        case .salt: "Salt"
        }
    }
}
