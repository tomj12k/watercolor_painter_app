import Foundation

public struct StrokeSamplingResult: Equatable, Sendable {
    public let points: [StrokePoint]
    public let distanceToNextSample: Double
    public let reachedPointLimit: Bool

    public init(points: [StrokePoint], distanceToNextSample: Double, reachedPointLimit: Bool) {
        self.points = points
        self.distanceToNextSample = distanceToNextSample
        self.reachedPointLimit = reachedPointLimit
    }
}

public enum StrokeSampler {
    /// Creates evenly spaced samples from just after `from` through `to`.
    /// The destination is always included, while short segments produce only it.
    public static func interpolate(
        from: StrokePoint,
        to: StrokePoint,
        spacing: Double
    ) -> [StrokePoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = hypot(dx, dy)

        guard distance >= spacing, spacing.isFinite, spacing > 0 else {
            return [to]
        }

        let sampleCount = Int(ceil(distance / spacing))
        return (1...sampleCount).map { index in
            if index == sampleCount {
                return to
            }

            let fraction = Double(index) / Double(sampleCount)
            return StrokePoint(
                x: from.x + (to.x - from.x) * fraction,
                y: from.y + (to.y - from.y) * fraction,
                pressure: from.pressure + (to.pressure - from.pressure) * fraction,
                tiltX: from.tiltX + (to.tiltX - from.tiltX) * fraction,
                tiltY: from.tiltY + (to.tiltY - from.tiltY) * fraction,
                time: from.time + (to.time - from.time) * fraction
            )
        }
    }

    /// Samples a segment at fixed arc-length intervals while carrying the distance to the
    /// next sample across input events. The supplied point limit is applied before points are
    /// allocated or interpolated.
    public static func sample(
        from: StrokePoint,
        to: StrokePoint,
        spacing: Double,
        distanceToNextSample: Double,
        maximumPointCount: Int
    ) -> StrokeSamplingResult {
        let fallbackDistance = spacing.isFinite && spacing > 0 ? spacing : 0
        guard maximumPointCount > 0 else {
            return StrokeSamplingResult(
                points: [],
                distanceToNextSample: fallbackDistance,
                reachedPointLimit: true
            )
        }
        guard spacing.isFinite, spacing > 0 else {
            return StrokeSamplingResult(
                points: [],
                distanceToNextSample: 0,
                reachedPointLimit: false
            )
        }

        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > 0 else {
            return StrokeSamplingResult(
                points: [],
                distanceToNextSample: normalizedDistanceToNextSample(distanceToNextSample, spacing: spacing),
                reachedPointLimit: false
            )
        }

        let nextSampleDistance = normalizedDistanceToNextSample(distanceToNextSample, spacing: spacing)
        guard distance >= nextSampleDistance else {
            return StrokeSamplingResult(
                points: [],
                distanceToNextSample: nextSampleDistance - distance,
                reachedPointLimit: false
            )
        }

        let remainingAfterFirst = distance - nextSampleDistance
        let maximumAdditionalSamples = maximumPointCount - 1
        let additionalSampleCount: Int
        if remainingAfterFirst / spacing >= Double(maximumAdditionalSamples) {
            additionalSampleCount = maximumAdditionalSamples
        } else {
            additionalSampleCount = Int((remainingAfterFirst / spacing).rounded(.down))
        }
        let sampleCount = additionalSampleCount + 1
        let reachedPointLimit = sampleCount == maximumPointCount
        var points: [StrokePoint] = []
        points.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let sampleDistance = nextSampleDistance + Double(index) * spacing
            let fraction = sampleDistance / distance
            points.append(interpolatedPoint(from: from, to: to, fraction: fraction))
        }

        let nextDistance = nextSampleDistance + Double(sampleCount) * spacing - distance
        return StrokeSamplingResult(
            points: points,
            distanceToNextSample: normalizedRemainder(nextDistance, spacing: spacing),
            reachedPointLimit: reachedPointLimit
        )
    }

    private static func normalizedDistanceToNextSample(_ distance: Double, spacing: Double) -> Double {
        guard distance.isFinite, distance > 0 else { return spacing }
        return distance
    }

    private static func normalizedRemainder(_ distance: Double, spacing: Double) -> Double {
        let tolerance = max(1e-9, spacing * 1e-12)
        return distance <= tolerance ? spacing : distance
    }

    private static func interpolatedPoint(
        from: StrokePoint,
        to: StrokePoint,
        fraction: Double
    ) -> StrokePoint {
        StrokePoint(
            x: from.x + (to.x - from.x) * fraction,
            y: from.y + (to.y - from.y) * fraction,
            pressure: from.pressure + (to.pressure - from.pressure) * fraction,
            tiltX: from.tiltX + (to.tiltX - from.tiltX) * fraction,
            tiltY: from.tiltY + (to.tiltY - from.tiltY) * fraction,
            time: from.time + (to.time - from.time) * fraction
        )
    }
}
