import Foundation
import Metal
import Testing
@testable import WatercolorEngine

@Suite @MainActor struct BrushMatrixExportTests {
    @Test func exportsDeterministicBrushMatrixWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WATERCOLOR_EXPORT_BRUSH_MATRIX"] == "1" else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let outputURL = URL(
            fileURLWithPath: environment["WATERCOLOR_BRUSH_MATRIX_PATH"]
                ?? "/tmp/watercolor-brush-matrix.png"
        )

        let result = try BrushMatrixExporter.export(to: outputURL, device: device)

        #expect(result.sectionCount == 4)
        #expect(result.sampleCount == 20)
        #expect(result.width >= 1_000)
        #expect(result.height >= 700)
        #expect(result.nonemptySampleCount == result.sampleCount)
        #expect(try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 32_000)
    }
}
