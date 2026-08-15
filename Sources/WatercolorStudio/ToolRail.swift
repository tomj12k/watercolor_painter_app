import SwiftUI
import WatercolorCore

struct ToolRail: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(PaintTool.allCases, id: \.self) { tool in
                toolButton(tool)
            }

            Spacer(minLength: 8)

            Text("\(Int(model.brush.size.rounded()))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(StudioPalette.graphite)
                .accessibilityLabel("Brush size")
                .accessibilityValue("\(Int(model.brush.size.rounded())) points")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(StudioPalette.carbon)
    }

    private func toolButton(_ tool: PaintTool) -> some View {
        let isSelected = model.selectedTool == tool
        return Button {
            model.selectedTool = tool
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? StudioPalette.cobalt.opacity(0.82) : Color.clear)

                if isSelected {
                    Rectangle()
                        .fill(StudioPalette.fiber)
                        .frame(width: 2, height: 20)
                }

                Image(systemName: tool.symbolName)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? StudioPalette.fiber : StudioPalette.graphite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 40, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(tool.displayName) (\(tool.shortcut.uppercased()))")
        .accessibilityLabel(tool.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension PaintTool {
    var displayName: String {
        switch self {
        case .brush: "Brush"
        case .water: "Water"
        case .eraser: "Eraser"
        case .smudge: "Smudge"
        case .smear: "Smear"
        case .dry: "Dry"
        }
    }

    var shortcut: String {
        switch self {
        case .brush: "b"
        case .water: "w"
        case .eraser: "e"
        case .smudge: "s"
        case .smear: "m"
        case .dry: "d"
        }
    }

    var symbolName: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .water: "drop"
        case .eraser: "eraser"
        case .smudge: "hand.draw"
        case .smear: "arrow.left.and.right"
        case .dry: "wind"
        }
    }
}
