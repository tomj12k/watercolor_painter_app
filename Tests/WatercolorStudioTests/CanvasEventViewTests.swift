import CoreGraphics
import Foundation
import Testing
import WatercolorCore
@testable import WatercolorStudio

@Suite struct CanvasStrokeBuilderTests {
    @Test func completedStrokeSnapshotsSettingsAndClampsEveryInput() {
        let layerID = UUID(uuidString: "75C15CB5-C88E-4F83-B590-578F87DAD64A")!
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))

        builder.begin(
            layerID: layerID,
            tool: .smear,
            brush: brush,
            point: .init(x: -10, y: 1400, pressure: 4, tiltX: -3, tiltY: 2, time: 1)
        )
        let stroke = builder.finish()

        #expect(stroke?.layerID == layerID)
        #expect(stroke?.tool == .smear)
        #expect(stroke?.brush == brush)
        #expect(stroke?.points == [
            StrokePoint(x: 0, y: 1200, pressure: 1, tiltX: -1, tiltY: 1, time: 1)
        ])
    }

    @Test func consecutiveSamplesUseEighteenPercentOfPressureScaledDiameter() throws {
        var brush = BrushSettings.default
        brush.size = 100
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let layerID = UUID(uuidString: "05E428FB-8CE0-40E7-8383-F61B67408BE1")!

        builder.begin(
            layerID: layerID,
            tool: .brush,
            brush: brush,
            point: .init(x: 0, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 0)
        )
        builder.append(.init(x: 18, y: 100, pressure: 0.5, tiltX: 0, tiltY: 0, time: 2))

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points.map(\.x) == [0, 9, 18])
        #expect(stroke.points.map(\.time) == [0, 1, 2])
    }

    @Test func duplicateMouseAndTabletSamplesDoNotCreateExtraPointsOrCommands() throws {
        var builder = CanvasStrokeBuilder(canvasSize: .init(width: 1600, height: 1200))
        let point = StrokePoint(x: 200, y: 300, pressure: 0.7, tiltX: 0.2, tiltY: -0.1, time: 4)

        builder.begin(layerID: UUID(), tool: .brush, brush: .default, point: point)
        builder.append(point)

        let completedStroke = builder.finish()
        let stroke = try #require(completedStroke)
        #expect(stroke.points == [point])
        #expect(builder.finish() == nil)
    }
}
