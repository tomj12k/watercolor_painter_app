import Foundation

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
}
