import Testing
@testable import WatercolorCore

@Suite struct StrokeSamplerTests {
    @Test func samplerFillsFastStrokeWithoutLargeGaps() {
        let a = StrokePoint(x: 0, y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        let b = StrokePoint(x: 100, y: 0, pressure: 0.5, tiltX: 0.2, tiltY: 0, time: 1)
        let points = StrokeSampler.interpolate(from: a, to: b, spacing: 12)
        #expect(points.count == 9)
        #expect(points.last?.x == 100)
    }

    @Test func samplerInterpolatesAllPointFieldsLinearly() {
        let a = StrokePoint(x: 0, y: 0, pressure: 1, tiltX: -1, tiltY: 0, time: 2)
        let b = StrokePoint(x: 20, y: 0, pressure: 0, tiltX: 1, tiltY: 1, time: 6)

        let points = StrokeSampler.interpolate(from: a, to: b, spacing: 10)

        #expect(points.count == 2)
        #expect(points[0] == StrokePoint(x: 10, y: 0, pressure: 0.5, tiltX: 0, tiltY: 0.5, time: 4))
        #expect(points[1] == b)
    }

    @Test func samplerReturnsOnlyDestinationForShortSegment() {
        let a = StrokePoint(x: 0, y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
        let b = StrokePoint(x: 5, y: 0, pressure: 0.5, tiltX: 0.2, tiltY: 0, time: 1)

        #expect(StrokeSampler.interpolate(from: a, to: b, spacing: 12) == [b])
    }
}
