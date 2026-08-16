import SwiftUI
import WatercolorCore

/// Customer-facing help shown from the Help menu. Tool rows are generated
/// from the tool definitions and the error table from an exhaustive switch,
/// so adding a tool or a failure code without documenting it fails the
/// help coverage tests or the build.
enum StudioHelp {
    static let windowIdentifier = "watercolor-studio-help"

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let body: String
    }

    static let sections: [Section] = [
        Section(
            title: "Getting started",
            body: """
            Watercolor Studio opens a new painting when it launches. Choose a \
            preset canvas or enter a custom size from 256 to 4096 pixels, pick \
            a paper, then paint on the canvas with the pointer or a tablet. \
            Paintings save as .watercolor documents that reopen exactly as \
            they looked, and the app asks for a save location right after the \
            first canvas is created.
            """
        ),
        Section(
            title: "Tools and shortcuts",
            body: toolGuide + """


            Press \u{2318}Z to Undo and \u{21E7}\u{2318}Z to Redo. Press \
            \u{2318}0 to fit the canvas in the window, and [ or ] to change \
            the brush size. Hold Space and drag, or drag with the middle \
            mouse button, to pan. Pinch to zoom. The paper always keeps a \
            corner on screen, so a stray scroll can never lose the painting.
            """
        ),
        Section(
            title: "Brush settings",
            body: """
            The brush inspector sets the brush identity (style, shape, hair, \
            texture), the paint load (size, opacity, flow, water, \
            granulation, edge bloom), and the stroke dynamics (spacing, \
            rotation, bristle and texture strength). Styles such as Wet on \
            wet or Dry brush apply a matched set of paint parameters while \
            keeping your color and dynamics.
            """
        ),
        Section(
            title: "Layers",
            body: """
            Paintings hold up to 12 layers. Use the layer list to add, \
            duplicate, delete, reorder, rename, hide, or merge layers, and to \
            set each layer's opacity. Painting always lands on the selected \
            layer, marked with a filled circle.
            """
        ),
        Section(
            title: "Undo, history, and capacity",
            body: """
            Every stroke and layer change is recorded, so Undo can step all \
            the way back. A painting holds up to 100,000 commands, 2,000,000 \
            stroke points, and 256 MB of history. When any limit passes 90%, \
            a capacity indicator appears next to the wetness readout naming \
            how full the painting is; undo strokes, or continue in a new \
            document, to keep painting.
            """
        ),
        Section(
            title: "Exporting",
            body: """
            Export PNG (\u{21E7}\u{2318}E) writes the composited painting as \
            a PNG at the canvas size. Exports never modify the painting or \
            its history, and a failed export never damages an existing file.
            """
        ),
        Section(
            title: "If something goes wrong",
            body: """
            Watercolor Studio never changes your painting when an operation \
            fails. If the renderer itself has a problem, a banner appears \
            over the canvas — your work so far is safe, and Try Again \
            rebuilds the renderer and resumes painting. Alerts include a \
            code you can copy for support:

            """ + errorCodeGuide
        )
    ]

    /// One customer-language sentence per failure code. The switch is
    /// exhaustive, so a new code cannot ship without a meaning.
    static func meaning(of code: StudioFailure.Code) -> String {
        switch code {
        case .resourceBudget:
            "The canvas and layer count need more graphics memory than this Mac can safely give. Reduce the canvas size or layer count."
        case .workBudget:
            "One rendering step was too large to run safely. Use fewer drying steps or a smaller canvas."
        case .capacity:
            "The painting reached a document limit. Undo strokes, or continue in a new document."
        case .metalUnavailable:
            "The Mac's graphics system was unavailable. Restart the app and check for macOS updates."
        case .gpuExecution:
            "The graphics processor could not finish a change. Try again, or save and reopen the painting."
        case .malformedDocument:
            "The file is not a valid Watercolor Studio painting. Open another copy or restore a backup."
        case .newerDocument:
            "The painting was made by a newer version of Watercolor Studio. Update the app, then reopen it."
        case .export:
            "The PNG could not be written. Choose another writable location and export again."
        case .unknown:
            "Something unexpected happened, and the painting is unchanged. Copy the details for support."
        }
    }

    private static var toolGuide: String {
        PaintTool.allCases
            .map { tool in
                "\(tool.displayName) (\(tool.shortcut.uppercased())) — \(blurb(for: tool))"
            }
            .joined(separator: "\n")
    }

    private static func blurb(for tool: PaintTool) -> String {
        switch tool {
        case .brush: "lays down pigment and water."
        case .water: "adds clear water so nearby pigment blooms and spreads."
        case .eraser: "lifts pigment and water from the layer."
        case .smudge: "pushes wet pigment in the drag direction."
        case .smear: "drags pigment strongly along the stroke."
        case .dry: "dries the paint under the stroke."
        }
    }

    private static var errorCodeGuide: String {
        let codes: [StudioFailure.Code] = [
            .resourceBudget, .workBudget, .capacity, .metalUnavailable,
            .gpuExecution, .malformedDocument, .newerDocument, .export, .unknown
        ]
        return codes
            .map { "\($0.rawValue) — \(meaning(of: $0))" }
            .joined(separator: "\n")
    }
}

struct StudioHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Watercolor Studio Help")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(StudioPalette.fiber)

                ForEach(StudioHelp.sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        StudioSectionTitle(title: section.title)
                        Text(section.body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(StudioPalette.fiber.opacity(0.92))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioPalette.carbon)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 640)
    }
}
