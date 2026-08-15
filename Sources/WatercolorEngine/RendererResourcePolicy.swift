import Metal
import WatercolorCore

struct RendererResourceEstimate: Equatable, Sendable {
    let liveBytes: Int
    let previewBytes: Int
    let candidateBytes: Int
    let totalBytes: Int
}

struct RendererResourcePolicy: Sendable {
    static let absoluteMaximumBytes = 2_147_483_648
    static let fallbackMaximumBytes = 536_870_912

    let maximumWorkingSetBytes: Int

    init(maximumWorkingSetBytes: Int) {
        self.maximumWorkingSetBytes = max(maximumWorkingSetBytes, 0)
    }

    init(recommendedMaximumWorkingSetBytes: UInt64) {
        let recommended = Int(clamping: recommendedMaximumWorkingSetBytes)
        let (fraction, didOverflow) = (recommended / 100).multipliedReportingOverflow(by: 35)
        let safeFraction = didOverflow ? Self.absoluteMaximumBytes : fraction
        self.init(
            maximumWorkingSetBytes: min(
                max(safeFraction, Self.fallbackMaximumBytes),
                Self.absoluteMaximumBytes
            )
        )
    }

    static func live(device: MTLDevice) -> Self {
        Self(recommendedMaximumWorkingSetBytes: device.recommendedMaxWorkingSetSize)
    }

    @discardableResult
    func admit(
        width: Int,
        height: Int,
        layerCapacity: Int,
        structuralCandidateCapacity: Int
    ) throws -> RendererResourceEstimate {
        guard width > 0,
              height > 0,
              layerCapacity > 0,
              structuralCandidateCapacity > 0
        else {
            throw overflowError
        }

        let pixelCount = try multiply(width, height)
        let liveBytes = try rendererBytes(pixelCount: pixelCount, layerCapacity: layerCapacity)
        let previewSliceBytes = try multiply(pixelCount, 10)
        let previewBytes = try multiply(previewSliceBytes, layerCapacity)
        let candidateBytes = try rendererBytes(
            pixelCount: pixelCount,
            layerCapacity: structuralCandidateCapacity
        )
        let liveAndPreviewBytes = try add(liveBytes, previewBytes)
        let totalBytes = try add(liveAndPreviewBytes, candidateBytes)

        guard totalBytes <= maximumWorkingSetBytes else {
            throw RendererError.resourceBudgetExceeded(
                required: totalBytes,
                available: maximumWorkingSetBytes
            )
        }
        return RendererResourceEstimate(
            liveBytes: liveBytes,
            previewBytes: previewBytes,
            candidateBytes: candidateBytes,
            totalBytes: totalBytes
        )
    }

    private func rendererBytes(pixelCount: Int, layerCapacity: Int) throws -> Int {
        let layerTextureBytesPerPixel = try multiply(layerCapacity, 20)
        let textureBytesPerPixel = try add(layerTextureBytesPerPixel, 8)
        let textureBytes = try multiply(pixelCount, textureBytesPerPixel)

        // The reduction pipeline allocates no more than one UInt32 per pixel-layer.
        // This device-independent upper bound is safe before pipeline allocation reveals
        // the device's threadgroup geometry.
        let reductionValues = try multiply(pixelCount, layerCapacity)
        let reductionBytes = try multiply(reductionValues, MemoryLayout<UInt32>.stride)
        let metadataBytes = try multiply(
            PaintingProject.maximumLayerCount,
            MemoryLayout<SIMD4<Float>>.stride
        )
        let finalMaximumBytes = MemoryLayout<UInt32>.stride

        let texturesAndReductionBytes = try add(textureBytes, reductionBytes)
        let buffersBytes = try add(metadataBytes, finalMaximumBytes)
        return try add(texturesAndReductionBytes, buffersBytes)
    }

    private func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, didOverflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !didOverflow else { throw overflowError }
        return result
    }

    private func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, didOverflow) = lhs.addingReportingOverflow(rhs)
        guard !didOverflow else { throw overflowError }
        return result
    }

    private var overflowError: RendererError {
        .resourceBudgetExceeded(required: .max, available: maximumWorkingSetBytes)
    }
}
