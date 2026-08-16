import Testing
import WatercolorCore
@testable import WatercolorStudio

/// The in-app help is the customer-facing documentation, so these tests fail
/// whenever a tool, shortcut, or error code exists without an explanation.
struct StudioHelpTests {
    private var allHelpText: String {
        StudioHelp.sections
            .map { "\($0.title)\n\($0.body)" }
            .joined(separator: "\n")
    }

    @Test func everySectionHasATitleAndABody() {
        #expect(StudioHelp.sections.count >= 6)
        for section in StudioHelp.sections {
            #expect(!section.title.isEmpty)
            #expect(!section.body.isEmpty)
        }
        let titles = StudioHelp.sections.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test func everyToolIsDocumentedWithItsShortcut() {
        let text = allHelpText
        for tool in PaintTool.allCases {
            #expect(text.contains(tool.displayName))
            #expect(text.contains("(\(tool.shortcut.uppercased()))"))
        }
    }

    @Test func everyCustomerErrorCodeHasAMeaning() {
        let text = allHelpText
        let codes: [StudioFailure.Code] = [
            .resourceBudget, .workBudget, .capacity, .metalUnavailable,
            .gpuExecution, .malformedDocument, .newerDocument, .export, .unknown
        ]
        for code in codes {
            #expect(text.contains(code.rawValue))
            #expect(!StudioHelp.meaning(of: code).isEmpty)
        }
    }

    @Test func helpCoversTheCoreCustomerTopics() {
        let text = allHelpText
        for topic in [
            "layer", "Undo", "Export", "capacity", "Try Again",
            ".watercolor", "256", "4096", "\u{2318}Z", "\u{2318}0"
        ] {
            #expect(text.contains(topic), "help is missing topic: \(topic)")
        }
    }
}
