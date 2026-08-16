import Foundation
import Metal
import Testing
import WatercolorCore
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
        #expect(result.samples.count == result.sampleCount)
        for (style, sample) in zip(
            WatercolorStyle.allCases,
            result.samples.filter { $0.category == .style }
        ) {
            #expect(sample.brush == sample.brush.applying(style))
        }

        let round = try #require(result.sample(category: .shape, value: BrushShape.round.rawValue))
        let fan = try #require(result.sample(category: .shape, value: BrushShape.fan.rawValue))
        let rigger = try #require(result.sample(category: .shape, value: BrushShape.rigger.rawValue))
        #expect(fan.metrics.laneCount == 5)
        #expect(rigger.metrics.area < round.metrics.area * 0.5)
        #expect(fan.caption.contains("lanes 5"))

        let squirrel = try #require(result.sample(category: .hair, value: BrushHair.squirrel.rawValue))
        let synthetic = try #require(result.sample(category: .hair, value: BrushHair.synthetic.rawValue))
        let bristle = try #require(result.sample(category: .hair, value: BrushHair.bristle.rawValue))
        let mop = try #require(result.sample(category: .hair, value: BrushHair.mop.rawValue))
        #expect(bristle.metrics.laneCount == 5)
        #expect(wetnessRatio(squirrel.metrics) > wetnessRatio(synthetic.metrics) * 1.25)
        #expect(wetnessRatio(mop.metrics) > wetnessRatio(bristle.metrics) * 1.5)
        #expect(bristle.caption.contains("wet"))

        let smooth = try #require(result.sample(category: .texture, value: BrushTexture.smooth.rawValue))
        let dryTexture = try #require(result.sample(category: .texture, value: BrushTexture.dry.rawValue))
        let salt = try #require(result.sample(category: .texture, value: BrushTexture.salt.rawValue))
        #expect(dryTexture.metrics.voidRatio > smooth.metrics.voidRatio + 0.05)
        #expect(salt.metrics.voidRatio > smooth.metrics.voidRatio + 0.005)
        #expect(dryTexture.caption.contains("rough"))

        let wash = try #require(
            result.sample(category: .style, value: WatercolorStyle.transparentWash.rawValue)
        )
        let wet = try #require(result.sample(category: .style, value: WatercolorStyle.wetOnWet.rawValue))
        let dryStyle = try #require(result.sample(category: .style, value: WatercolorStyle.dryBrush.rawValue))
        #expect(wet.metrics.wetnessMass > dryStyle.metrics.wetnessMass * 2)
        #expect(dryStyle.metrics.voidRatio > wash.metrics.voidRatio + 0.05)
        #expect(wet.caption.contains("spread"))
        #expect(try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 32_000)
    }

    private func wetnessRatio(_ metrics: BrushPhenotypeMetrics) -> Double {
        metrics.wetnessMass / max(metrics.pigmentMass, 0.000_001)
    }
}
