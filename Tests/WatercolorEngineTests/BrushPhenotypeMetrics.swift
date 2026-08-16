import Foundation
import Testing
@testable import WatercolorEngine

/// Test-only semantic measurements for a row-major scalar-field snapshot.
///
/// `alpha` must contain exactly `width * height` normalized samples. A malformed
/// grid measures as empty. The default foreground threshold is 1/256; callers
/// may supply any finite threshold in (0, 1]. Missing pigment or wetness entries
/// are zero and extras are ignored. Non-finite and negative field values are
/// zero. Alpha is additionally clamped to one.
///
/// Geometry uses the thresholded alpha mask. Orientation is the major-axis
/// angle in radians in [-pi/2, pi/2), and aspect ratio uses pixel-center moments
/// plus a pixel's intrinsic 1/12 variance on both axes. Roughness is four-neighbor
/// perimeter divided by the circumference of an equal-area circle. Voids are
/// enclosed four-connected background pixels. Projected cells form candidate
/// lanes by eight-neighbor digital connectivity: each minor-axis bin is split
/// into contiguous longitudinal runs, and runs connect across adjacent minor
/// bins only when their longitudinal ranges overlap or touch. A component is
/// persistent when its combined major-axis bins cover at least 60% of the stroke
/// and span at least 75% of its longitudinal extent. Spread is pigment-weighted
/// RMS distance from the pigment centroid, and edge concentration is the fraction
/// of in-mask pigment on the four-neighbor boundary.
struct BrushPhenotypeMetrics: Equatable {
    let area: Double
    let aspectRatio: Double
    let orientation: Double
    let edgeRoughness: Double
    let voidRatio: Double
    let laneCount: Int
    let pigmentMass: Double
    let wetnessMass: Double
    let spreadRadius: Double
    let edgeConcentration: Double

    private static let defaultCoverageThreshold = 1.0 / 256.0
    private static let pixelVariance = 1.0 / 12.0
    private static let minimumLaneOccupancyRatio = 0.60
    private static let minimumLaneSpanRatio = 0.75

    private struct LaneRun {
        let firstLongitudinalBin: Int
        let lastLongitudinalBin: Int
    }

    static func measure(
        width: Int,
        height: Int,
        alpha: [Double],
        pigment: [Double],
        wetness: [Double],
        coverageThreshold: Double = defaultCoverageThreshold
    ) -> Self {
        guard width > 0, height > 0 else { return .empty }
        let (pixelCount, didOverflow) = width.multipliedReportingOverflow(by: height)
        guard !didOverflow, pixelCount > 0, alpha.count == pixelCount else { return .empty }

        let threshold = coverageThreshold.isFinite
            && coverageThreshold > 0
            && coverageThreshold <= 1
            ? coverageThreshold
            : defaultCoverageThreshold
        let normalizedAlpha = alpha.map { value in
            guard value.isFinite, value > 0 else { return 0.0 }
            return min(value, 1)
        }
        let pigmentValues = (0..<pixelCount).map { index in
            sanitizedQuantity(index < pigment.count ? pigment[index] : 0)
        }
        let wetnessValues = (0..<pixelCount).map { index in
            sanitizedQuantity(index < wetness.count ? wetness[index] : 0)
        }
        let foreground = normalizedAlpha.map { $0 >= threshold }
        let foregroundIndices = foreground.indices.filter { foreground[$0] }

        let geometry = geometryMetrics(
            width: width,
            foregroundIndices: foregroundIndices
        )
        let boundary = boundaryMetrics(
            width: width,
            height: height,
            foreground: foreground,
            foregroundIndices: foregroundIndices
        )
        let holes = enclosedBackgroundCount(
            width: width,
            height: height,
            foreground: foreground
        )
        let pigmentStatistics = pigmentMetrics(
            width: width,
            foreground: foreground,
            boundary: boundary.pixels,
            values: pigmentValues
        )
        let area = Double(foregroundIndices.count)
        let voidDenominator = foregroundIndices.count + holes

        return Self(
            area: area,
            aspectRatio: geometry.aspectRatio,
            orientation: geometry.orientation,
            edgeRoughness: area > 0
                ? finiteOrZero(Double(boundary.perimeter) / (2 * sqrt(.pi * area)))
                : 0,
            voidRatio: voidDenominator > 0
                ? Double(holes) / Double(voidDenominator)
                : 0,
            laneCount: laneCount(
                width: width,
                orientation: geometry.orientation,
                foregroundIndices: foregroundIndices
            ),
            pigmentMass: saturatingSum(pigmentValues),
            wetnessMass: saturatingSum(wetnessValues),
            spreadRadius: pigmentStatistics.spreadRadius,
            edgeConcentration: pigmentStatistics.edgeConcentration
        )
    }

    /// Adapts the renderer's raw half-float fields without reproducing any
    /// deposition or simulation equation. Pigment alpha is the renderer's
    /// stored concentration, so it supplies both the coverage mask and the
    /// scalar pigment mass field; wetness remains its independent scalar field.
    static func measure(
        _ fields: RendererDebugLayerFields,
        coverageThreshold: Double = defaultCoverageThreshold
    ) -> Self {
        let pigmentConcentration = fields.pigment.map { Double($0.w) }
        return measure(
            width: fields.width,
            height: fields.height,
            alpha: pigmentConcentration,
            pigment: pigmentConcentration,
            wetness: fields.wetness.map(Double.init),
            coverageThreshold: coverageThreshold
        )
    }

    private static var empty: Self {
        Self(
            area: 0,
            aspectRatio: 1,
            orientation: 0,
            edgeRoughness: 0,
            voidRatio: 0,
            laneCount: 0,
            pigmentMass: 0,
            wetnessMass: 0,
            spreadRadius: 0,
            edgeConcentration: 0
        )
    }

    private static func geometryMetrics(
        width: Int,
        foregroundIndices: [Int]
    ) -> (aspectRatio: Double, orientation: Double) {
        guard !foregroundIndices.isEmpty else { return (1, 0) }
        let count = Double(foregroundIndices.count)
        let centroidX = foregroundIndices.reduce(0.0) { $0 + Double($1 % width) } / count
        let centroidY = foregroundIndices.reduce(0.0) { $0 + Double($1 / width) } / count
        var covarianceXX = 0.0
        var covarianceXY = 0.0
        var covarianceYY = 0.0
        for index in foregroundIndices {
            let dx = Double(index % width) - centroidX
            let dy = Double(index / width) - centroidY
            covarianceXX += dx * dx
            covarianceXY += dx * dy
            covarianceYY += dy * dy
        }
        covarianceXX = covarianceXX / count + pixelVariance
        covarianceXY /= count
        covarianceYY = covarianceYY / count + pixelVariance

        let difference = covarianceXX - covarianceYY
        let discriminant = hypot(difference, 2 * covarianceXY)
        let major = max((covarianceXX + covarianceYY + discriminant) / 2, pixelVariance)
        let minor = max((covarianceXX + covarianceYY - discriminant) / 2, pixelVariance)
        let orientation: Double
        if abs(difference) < 0.000_000_000_001,
           abs(covarianceXY) < 0.000_000_000_001 {
            orientation = 0
        } else {
            var candidate = 0.5 * atan2(2 * covarianceXY, difference)
            if candidate >= .pi / 2 {
                candidate -= .pi
            }
            orientation = candidate
        }
        return (finiteOrOne(sqrt(major / minor)), finiteOrZero(orientation))
    }

    private static func boundaryMetrics(
        width: Int,
        height: Int,
        foreground: [Bool],
        foregroundIndices: [Int]
    ) -> (perimeter: Int, pixels: [Bool]) {
        var perimeter = 0
        var boundary = Array(repeating: false, count: foreground.count)
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for index in foregroundIndices {
            let x = index % width
            let y = index / width
            for (dx, dy) in offsets {
                let neighborX = x + dx
                let neighborY = y + dy
                guard (0..<width).contains(neighborX),
                      (0..<height).contains(neighborY),
                      foreground[neighborY * width + neighborX]
                else {
                    perimeter += 1
                    boundary[index] = true
                    continue
                }
            }
        }
        return (perimeter, boundary)
    }

    private static func enclosedBackgroundCount(
        width: Int,
        height: Int,
        foreground: [Bool]
    ) -> Int {
        var exterior = Array(repeating: false, count: foreground.count)
        var queue: [Int] = []

        func borderIndices() -> [Int] {
            var indices = Array(0..<width)
            if height > 1 {
                indices += ((height - 1) * width..<(height * width))
            }
            if height > 2 {
                for y in 1..<(height - 1) {
                    indices.append(y * width)
                    if width > 1 {
                        indices.append(y * width + width - 1)
                    }
                }
            }
            return indices
        }

        for index in borderIndices() where !foreground[index] && !exterior[index] {
            exterior[index] = true
            queue.append(index)
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            let neighbors = [
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1)
            ]
            for (neighborX, neighborY) in neighbors
            where (0..<width).contains(neighborX) && (0..<height).contains(neighborY) {
                let neighbor = neighborY * width + neighborX
                guard !foreground[neighbor], !exterior[neighbor] else { continue }
                exterior[neighbor] = true
                queue.append(neighbor)
            }
        }
        return foreground.indices.reduce(into: 0) { count, index in
            if !foreground[index], !exterior[index] {
                count += 1
            }
        }
    }

    private static func laneCount(
        width: Int,
        orientation: Double,
        foregroundIndices: [Int]
    ) -> Int {
        guard !foregroundIndices.isEmpty else { return 0 }
        let tangentX = cos(orientation)
        let tangentY = sin(orientation)
        let normalX = -sin(orientation)
        let normalY = cos(orientation)
        var longitudinalBinsByMinorBin: [Int: Set<Int>] = [:]
        var firstLongitudinalBin = Int.max
        var lastLongitudinalBin = Int.min
        for index in foregroundIndices {
            let x = Double(index % width)
            let y = Double(index / width)
            let longitudinalBin = Int((x * tangentX + y * tangentY).rounded())
            let minorBin = Int((x * normalX + y * normalY).rounded())
            longitudinalBinsByMinorBin[minorBin, default: []].insert(longitudinalBin)
            firstLongitudinalBin = min(firstLongitudinalBin, longitudinalBin)
            lastLongitudinalBin = max(lastLongitudinalBin, longitudinalBin)
        }
        let longitudinalBinCount = lastLongitudinalBin - firstLongitudinalBin + 1
        guard longitudinalBinCount > 0 else { return 0 }
        let candidateComponents = candidateLaneComponents(
            longitudinalBinsByMinorBin: longitudinalBinsByMinorBin
        )
        return candidateComponents.reduce(into: 0) { count, bins in
            guard let first = bins.min(), let last = bins.max() else { return }
            let occupancyRatio = Double(bins.count) / Double(longitudinalBinCount)
            let spanRatio = Double(last - first + 1) / Double(longitudinalBinCount)
            if occupancyRatio >= minimumLaneOccupancyRatio,
               spanRatio >= minimumLaneSpanRatio {
                count += 1
            }
        }
    }

    private static func candidateLaneComponents(
        longitudinalBinsByMinorBin: [Int: Set<Int>]
    ) -> [Set<Int>] {
        var runs: [LaneRun] = []
        var runIndicesByMinorBin: [Int: [Int]] = [:]
        for minorBin in longitudinalBinsByMinorBin.keys.sorted() {
            guard let longitudinalBins = longitudinalBinsByMinorBin[minorBin] else {
                continue
            }
            for run in contiguousLaneRuns(longitudinalBins) {
                runIndicesByMinorBin[minorBin, default: []].append(runs.count)
                runs.append(run)
            }
        }

        var adjacency = Array(repeating: [Int](), count: runs.count)
        for minorBin in runIndicesByMinorBin.keys.sorted() {
            let (previousMinorBin, didOverflow) = minorBin.subtractingReportingOverflow(1)
            guard let currentIndices = runIndicesByMinorBin[minorBin],
                  !didOverflow,
                  let previousIndices = runIndicesByMinorBin[previousMinorBin] else {
                continue
            }
            for currentIndex in currentIndices {
                for previousIndex in previousIndices
                where laneRunsOverlapOrTouch(runs[currentIndex], runs[previousIndex]) {
                    adjacency[currentIndex].append(previousIndex)
                    adjacency[previousIndex].append(currentIndex)
                }
            }
        }

        var components: [Set<Int>] = []
        var visited = Array(repeating: false, count: runs.count)
        for startIndex in runs.indices where !visited[startIndex] {
            var component: Set<Int> = []
            var pending = [startIndex]
            visited[startIndex] = true
            while let index = pending.popLast() {
                let run = runs[index]
                component.formUnion(run.firstLongitudinalBin...run.lastLongitudinalBin)
                for neighbor in adjacency[index] where !visited[neighbor] {
                    visited[neighbor] = true
                    pending.append(neighbor)
                }
            }
            components.append(component)
        }
        return components
    }

    private static func contiguousLaneRuns(_ bins: Set<Int>) -> [LaneRun] {
        guard var first = bins.min() else { return [] }
        var last = first
        var runs: [LaneRun] = []
        for bin in bins.sorted().dropFirst() {
            let (next, didOverflow) = last.addingReportingOverflow(1)
            if !didOverflow, bin == next {
                last = bin
            } else {
                runs.append(LaneRun(
                    firstLongitudinalBin: first,
                    lastLongitudinalBin: last
                ))
                first = bin
                last = bin
            }
        }
        runs.append(LaneRun(
            firstLongitudinalBin: first,
            lastLongitudinalBin: last
        ))
        return runs
    }

    private static func laneRunsOverlapOrTouch(_ lhs: LaneRun, _ rhs: LaneRun) -> Bool {
        if lhs.lastLongitudinalBin < rhs.firstLongitudinalBin {
            let (next, didOverflow) = lhs.lastLongitudinalBin.addingReportingOverflow(1)
            return !didOverflow && next == rhs.firstLongitudinalBin
        }
        if rhs.lastLongitudinalBin < lhs.firstLongitudinalBin {
            let (next, didOverflow) = rhs.lastLongitudinalBin.addingReportingOverflow(1)
            return !didOverflow && next == lhs.firstLongitudinalBin
        }
        return true
    }

    private static func pigmentMetrics(
        width: Int,
        foreground: [Bool],
        boundary: [Bool],
        values: [Double]
    ) -> (spreadRadius: Double, edgeConcentration: Double) {
        guard let maximum = values.max(), maximum > 0 else { return (0, 0) }
        let scaled = values.map { $0 / maximum }
        let scaledMass = scaled.reduce(0, +)
        guard scaledMass > 0, scaledMass.isFinite else { return (0, 0) }
        let centroidX = scaled.indices.reduce(0.0) {
            $0 + scaled[$1] * Double($1 % width)
        } / scaledMass
        let centroidY = scaled.indices.reduce(0.0) {
            $0 + scaled[$1] * Double($1 / width)
        } / scaledMass
        let radialMoment = scaled.indices.reduce(0.0) { sum, index in
            let dx = Double(index % width) - centroidX
            let dy = Double(index / width) - centroidY
            return sum + scaled[index] * (dx * dx + dy * dy)
        } / scaledMass

        var inMaskMass = 0.0
        var boundaryMass = 0.0
        for index in scaled.indices where foreground[index] {
            inMaskMass += scaled[index]
            if boundary[index] {
                boundaryMass += scaled[index]
            }
        }
        return (
            finiteOrZero(sqrt(max(radialMoment, 0))),
            inMaskMass > 0 ? finiteOrZero(boundaryMass / inMaskMass) : 0
        )
    }

    private static func sanitizedQuantity(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func saturatingSum(_ values: [Double]) -> Double {
        values.reduce(0) { partial, value in
            let sum = partial + value
            return sum.isFinite ? sum : .greatestFiniteMagnitude
        }
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func finiteOrOne(_ value: Double) -> Double {
        value.isFinite && value >= 1 ? value : 1
    }
}

@Suite struct BrushPhenotypeMetricTests {
    @Test func fourByTwoRectangleHasHandDerivedAreaAspectAndRoughness() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 4,
            height: 2,
            alpha: [
                1, 1, 1, 1,
                1, 1, 1, 1
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 8)
        #expect(abs(metrics.aspectRatio - 2) < 0.000_001)
        #expect(abs(metrics.orientation) < 0.000_001)
        #expect(abs(metrics.edgeRoughness - 1.196_826_841_204_298_2) < 0.000_001)
    }

    @Test func verticalAndTiltedMasksHaveKnownPrincipalOrientations() {
        let vertical = BrushPhenotypeMetrics.measure(
            width: 2,
            height: 4,
            alpha: Array(repeating: 1, count: 8),
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )
        let tilted = BrushPhenotypeMetrics.measure(
            width: 3,
            height: 3,
            alpha: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(abs(abs(vertical.orientation) - .pi / 2) < 0.000_001)
        #expect(abs(tilted.orientation - .pi / 4) < 0.000_001)
        #expect(abs(tilted.aspectRatio - 4.123_105_625_617_661) < 0.000_001)
    }

    @Test func twoEnclosedSinglePixelHolesHaveKnownVoidRatio() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 7,
            height: 5,
            alpha: [
                0, 0, 0, 0, 0, 0, 0,
                0, 1, 1, 1, 1, 1, 0,
                0, 1, 0, 1, 0, 1, 0,
                0, 1, 1, 1, 1, 1, 0,
                0, 0, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 13)
        #expect(abs(metrics.voidRatio - 0.133_333_333_333_333_33) < 0.000_001)
        #expect(metrics.laneCount == 1)
    }

    @Test func twoSeparatedFullLengthRowsMeasureAsTwoPersistentLanes() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 8,
            height: 5,
            alpha: [
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 1, 1, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 1, 1, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 16)
        #expect(metrics.laneCount == 2)
        #expect(metrics.voidRatio == 0)
    }

    @Test func twoShallowRotatedFullLanesMeasureAsTwoPersistentBands() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 32,
            height: 24,
            alpha: alphaMask(
                width: 32,
                height: 24,
                foreground: [
                    (10, 9), (11, 9), (12, 9), (13, 9), (14, 9), (15, 9),
                    (16, 9), (17, 9), (18, 9), (19, 9), (20, 10), (21, 10),
                    (10, 11), (11, 12), (12, 12), (13, 12), (14, 12), (15, 12),
                    (16, 12), (17, 12), (18, 12), (19, 12), (20, 13), (21, 13)
                ]
            ),
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 24)
        #expect((6.0...6.5).contains(metrics.orientation * 180 / .pi))
        #expect(metrics.laneCount == 2)
    }

    @Test func twoMirroredShallowRotatedFullLanesMeasureAsTwoPersistentBands() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 32,
            height: 24,
            alpha: alphaMask(
                width: 32,
                height: 24,
                foreground: [
                    (12, 9), (13, 9), (14, 9), (15, 9), (16, 9), (17, 9),
                    (18, 9), (19, 9), (20, 9), (21, 9), (10, 10), (11, 10),
                    (21, 11), (12, 12), (13, 12), (14, 12), (15, 12), (16, 12),
                    (17, 12), (18, 12), (19, 12), (20, 12), (10, 13), (11, 13)
                ]
            ),
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 24)
        #expect((-6.5 ... -6.0).contains(metrics.orientation * 180 / .pi))
        #expect(metrics.laneCount == 2)
    }

    @Test func adjacentLongitudinallyDisconnectedFragmentsDoNotFormPersistentBands() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 8,
            height: 7,
            alpha: [
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 1, 1, 1,
                1, 1, 1, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 12)
        #expect(abs(metrics.orientation) < 0.000_001)
        #expect(metrics.laneCount == 0)
    }

    @Test func transitiveSameRowFragmentsDoNotConnectSeparateLaneComponents() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 8,
            height: 7,
            alpha: [
                1, 1, 1, 0, 0, 0, 0, 0,
                0, 0, 1, 0, 0, 1, 0, 0,
                0, 0, 0, 0, 0, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 1, 1, 1,
                0, 0, 1, 0, 0, 1, 0, 0,
                1, 1, 1, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 16)
        #expect(abs(metrics.orientation) < 0.000_001)
        #expect(metrics.laneCount == 0)
    }

    @Test func staggeredHalfLengthBandsDoNotMeasureAsPersistentLanes() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 8,
            height: 9,
            alpha: [
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 1, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 1, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 1, 1, 1, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 1, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 16)
        #expect(metrics.laneCount == 0)
    }

    @Test func alternatingDisconnectedNoiseDoesNotMeasureAsPersistentLanes() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 8,
            height: 9,
            alpha: [
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 0, 1, 0, 1, 0, 1, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 1, 0, 1, 0, 1, 0, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 1, 0, 1, 0, 1, 0, 1,
                0, 0, 0, 0, 0, 0, 0, 0,
                1, 0, 1, 0, 1, 0, 1, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            ],
            pigment: [],
            wetness: [],
            coverageThreshold: 0.5
        )

        #expect(metrics.area == 16)
        #expect(metrics.laneCount == 0)
    }

    @Test func massesSpreadAndEdgeConcentrationUseIndependentScalarFields() {
        let metrics = BrushPhenotypeMetrics.measure(
            width: 3,
            height: 3,
            alpha: Array(repeating: 1, count: 9),
            pigment: [
                1, 1, 1,
                1, 4, 1,
                1, 1, 1
            ],
            wetness: [
                1, 2, 3,
                4, 5, 6,
                7, 8, 9
            ],
            coverageThreshold: 0.5
        )

        #expect(metrics.pigmentMass == 12)
        #expect(metrics.wetnessMass == 45)
        #expect(abs(metrics.spreadRadius - 1) < 0.000_001)
        #expect(abs(metrics.edgeConcentration - 0.666_666_666_666_666_6) < 0.000_001)
    }

    @Test func invalidAndDegenerateInputsProduceFiniteNeutralMetrics() {
        let sanitized = BrushPhenotypeMetrics.measure(
            width: 3,
            height: 1,
            alpha: [0.49, 0.5, .nan],
            pigment: [-1, .infinity, 2],
            wetness: [.nan, -3, 4],
            coverageThreshold: 0.5
        )
        let empty = BrushPhenotypeMetrics.measure(
            width: .max,
            height: 2,
            alpha: [1],
            pigment: [1],
            wetness: [1],
            coverageThreshold: .nan
        )

        #expect(sanitized.area == 1)
        #expect(sanitized.aspectRatio == 1)
        #expect(sanitized.pigmentMass == 2)
        #expect(sanitized.wetnessMass == 4)
        #expect(sanitized.edgeConcentration == 0)
        #expect(empty.area == 0)
        #expect(empty.aspectRatio == 1)
        #expect(empty.laneCount == 0)
        for value in metricScalars(sanitized) + metricScalars(empty) {
            #expect(value.isFinite)
        }
    }

    private func metricScalars(_ metrics: BrushPhenotypeMetrics) -> [Double] {
        [
            metrics.area,
            metrics.aspectRatio,
            metrics.orientation,
            metrics.edgeRoughness,
            metrics.voidRatio,
            metrics.pigmentMass,
            metrics.wetnessMass,
            metrics.spreadRadius,
            metrics.edgeConcentration
        ]
    }

    private func alphaMask(
        width: Int,
        height: Int,
        foreground: [(x: Int, y: Int)]
    ) -> [Double] {
        var alpha = Array(repeating: 0.0, count: width * height)
        for point in foreground {
            alpha[point.y * width + point.x] = 1
        }
        return alpha
    }
}
