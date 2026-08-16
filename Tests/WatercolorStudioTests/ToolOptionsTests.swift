import Testing
import WatercolorCore
@testable import WatercolorStudio

/// Every tool must offer the controls that actually change its output, and
/// none that silently do nothing. These tests pin that contract so a new
/// tool cannot ship without declared options.
struct ToolOptionsTests {
    @Test func everyToolDeclaresOptionsIncludingSize() {
        for tool in PaintTool.allCases {
            #expect(!tool.inspectorOptions.isEmpty, "tool \(tool) has no options")
            #expect(tool.inspectorOptions.contains(.size), "tool \(tool) must offer size")
        }
    }

    @Test func pigmentControlsBelongToTheBrushAlone() {
        #expect(PaintTool.brush.inspectorOptions.contains(.identity))
        #expect(PaintTool.brush.inspectorOptions.contains(.color))
        #expect(PaintTool.brush.inspectorOptions.contains(.flow))
        #expect(PaintTool.brush.inspectorOptions.contains(.granulation))
        for tool in PaintTool.allCases where tool != .brush {
            #expect(!tool.inspectorOptions.contains(.identity), "\(tool) shows brush identity")
            #expect(!tool.inspectorOptions.contains(.color), "\(tool) shows pigment color")
            #expect(!tool.inspectorOptions.contains(.flow), "\(tool) shows paint flow")
            #expect(!tool.inspectorOptions.contains(.granulation), "\(tool) shows granulation")
        }
    }

    @Test func strengthToolsOfferAStrengthControlWithAnHonestLabel() {
        for tool in [PaintTool.eraser, .smudge, .smear, .dry] {
            #expect(tool.inspectorOptions.contains(.strength), "\(tool) must offer strength")
            #expect(tool.strengthTitle == "Strength")
            #expect(tool.inspectorOptions.contains(.spacing))
        }
        #expect(PaintTool.brush.strengthTitle == "Opacity")
        // Water has no lift strength — its load is the water amount.
        #expect(!PaintTool.water.inspectorOptions.contains(.strength))
        #expect(PaintTool.water.inspectorOptions.contains(.waterLoad))
        #expect(PaintTool.water.inspectorOptions.contains(.edgeBloom))
    }

    @Test func everyToolNamesItsOptionsPane() {
        for tool in PaintTool.allCases {
            #expect(!tool.optionsPaneTitle.isEmpty)
        }
        #expect(PaintTool.brush.optionsPaneTitle == "Paint")
        #expect(PaintTool.eraser.optionsPaneTitle == "Eraser")
    }
}
