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

    @Test func samplerKeepsResidualDistanceAcrossEventBoundaries() {
        let start = StrokePoint(x: 0, y: 0, pressure: 0, tiltX: -1, tiltY: -1, time: 0)
        let end = StrokePoint(x: 100, y: 0, pressure: 1, tiltX: 1, tiltY: 1, time: 10)

        func sampledPoints(for input: [StrokePoint]) -> [StrokePoint] {
            var samples = [input[0]]
            var distanceToNextSample = 18.0
            for index in 1..<input.count {
                let result = StrokeSampler.sample(
                    from: input[index - 1],
                    to: input[index],
                    spacing: 18,
                    distanceToNextSample: distanceToNextSample,
                    maximumPointCount: 1_000
                )
                samples.append(contentsOf: result.points)
                distanceToNextSample = result.distanceToNextSample
            }
            return samples
        }

        let coarse = sampledPoints(for: [start, end])
        let fine = sampledPoints(for: (0...100).map { step in
            StrokePoint(
                x: Double(step), y: 0,
                pressure: Double(step) / 100,
                tiltX: -1 + 2 * Double(step) / 100,
                tiltY: -1 + 2 * Double(step) / 100,
                time: Double(step) / 10
            )
        })

        #expect(coarse.map(\.x) == [0, 18, 36, 54, 72, 90])
        #expect(coarse.count == fine.count)
        #expect(zip(coarse, fine).allSatisfy { coarsePoint, finePoint in
            abs(coarsePoint.x - finePoint.x) < 1e-9
                && abs(coarsePoint.y - finePoint.y) < 1e-9
                && abs(coarsePoint.pressure - finePoint.pressure) < 1e-9
                && abs(coarsePoint.tiltX - finePoint.tiltX) < 1e-9
                && abs(coarsePoint.tiltY - finePoint.tiltY) < 1e-9
                && abs(coarsePoint.time - finePoint.time) < 1e-9
        })
        #expect(coarse.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite
                && $0.tiltX.isFinite && $0.tiltY.isFinite && $0.time.isFinite
        })
    }

    @Test func samplerStopsBeforeInterpolatingPastItsBatchLimit() {
        let start = StrokePoint(x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        let end = StrokePoint(x: 100, y: 0, pressure: 1, tiltX: 1, tiltY: 1, time: 10)

        let result = StrokeSampler.sample(
            from: start,
            to: end,
            spacing: 18,
            distanceToNextSample: 18,
            maximumPointCount: 2
        )

        #expect(result.points.map(\.x) == [18, 36])
        #expect(result.reachedPointLimit)
    }

    @Test func samplerAcceptsAnExactlyFullBatchLimit() {
        let start = StrokePoint(x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0, time: 0)
        let end = StrokePoint(x: 36, y: 0, pressure: 1, tiltX: 1, tiltY: 1, time: 2)

        let result = StrokeSampler.sample(
            from: start,
            to: end,
            spacing: 18,
            distanceToNextSample: 18,
            maximumPointCount: 2
        )

        #expect(result.points.map(\.x) == [18, 36])
        #expect(!result.reachedPointLimit)
    }
}
