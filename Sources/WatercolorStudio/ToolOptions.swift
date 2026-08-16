import WatercolorCore

/// One inspector control (or control group) that a tool can offer. The
/// inspector shows exactly the options a tool declares, so a control never
/// appears for a tool whose rendering ignores it.
enum ToolInspectorOption: Equatable {
    /// Style, shape, hair, and texture pickers plus the recipe line.
    case identity
    /// The pigment color picker and swatches.
    case color
    case size
    /// The opacity slot; labeled per tool (`strengthTitle`).
    case strength
    case flow
    case waterLoad
    case granulation
    case edgeBloom
    /// Spacing, rotation, bristle, and texture strength.
    case fullDynamics
    /// Spacing alone, for tools whose footprint dynamics are fixed.
    case spacing
}

extension PaintTool {
    /// The controls that genuinely change this tool's output.
    var inspectorOptions: [ToolInspectorOption] {
        switch self {
        case .brush:
            [.identity, .color, .size, .strength, .flow, .waterLoad,
             .granulation, .edgeBloom, .fullDynamics]
        case .water:
            [.size, .waterLoad, .edgeBloom, .spacing]
        case .eraser, .smudge, .smear, .dry:
            [.size, .strength, .spacing]
        }
    }

    /// The label on the opacity slot: pigment transparency for the brush,
    /// lift or pull strength for the tools that erase, dry, or move paint.
    var strengthTitle: String? {
        switch self {
        case .brush: "Opacity"
        case .water: nil
        case .eraser, .smudge, .smear, .dry: "Strength"
        }
    }

    /// The heading over the tool's numeric options.
    var optionsPaneTitle: String {
        self == .brush ? "Paint" : displayName
    }
}
