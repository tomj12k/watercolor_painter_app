import Testing
@testable import WatercolorEngine

@Suite struct RendererResourcePolicyTests {
    @Test func unsafeMaximumProjectIsRejectedBeforeRendererAllocation() {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: 2 * 1024 * 1024 * 1024)

        #expect(throws: RendererError.self) {
            try policy.admit(
                width: 4_096,
                height: 4_096,
                layerCapacity: 12,
                structuralCandidateCapacity: 12
            )
        }
    }

    @Test func defaultTwelveLayerProjectFitsTheReferenceBudget() throws {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: 2 * 1024 * 1024 * 1024)

        let estimate = try policy.admit(
            width: 1_600,
            height: 1_200,
            layerCapacity: 12,
            structuralCandidateCapacity: 12
        )

        #expect(estimate.totalBytes < policy.maximumWorkingSetBytes)
    }

    @Test func estimateIncludesTexturesPreviewAndAllocatedBuffers() throws {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: .max)

        let estimate = try policy.admit(
            width: 8,
            height: 4,
            layerCapacity: 2,
            structuralCandidateCapacity: 3
        )

        // 32 pixels × 48 texture bytes + 32 × 2 × 4 reduction bytes + 192 metadata + 4 final maximum.
        #expect(estimate.liveBytes == 1_988)
        // One reusable rgba16Float pigment slice and one r16Float wetness slice.
        #expect(estimate.previewBytes == 320)
        // Candidate renderer bytes (2,756) plus its own reusable 320-byte preview pair.
        #expect(estimate.candidateBytes == 3_076)
        #expect(estimate.totalBytes == 5_384)
    }

    @Test func estimateAtTheBudgetBoundaryIsAdmitted() throws {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: 5_384)

        let estimate = try policy.admit(
            width: 8,
            height: 4,
            layerCapacity: 2,
            structuralCandidateCapacity: 3
        )

        #expect(estimate.totalBytes == 5_384)
    }

    @Test func estimateAboveTheBudgetReportsRequiredAndAvailableBytes() {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: 5_383)

        #expect(throws: RendererError.resourceBudgetExceeded(required: 5_384, available: 5_383)) {
            try policy.admit(
                width: 8,
                height: 4,
                layerCapacity: 2,
                structuralCandidateCapacity: 3
            )
        }
    }

    @Test func estimateRejectsIntegerOverflow() {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: .max)

        #expect(throws: RendererError.self) {
            try policy.admit(
                width: .max,
                height: .max,
                layerCapacity: 12,
                structuralCandidateCapacity: 12
            )
        }
    }

    @Test func layerByteArithmeticRejectsIntegerOverflow() {
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: .max)

        #expect(throws: RendererError.self) {
            try policy.admit(
                width: 1,
                height: 1,
                layerCapacity: .max,
                structuralCandidateCapacity: 1
            )
        }
    }

    @Test func zeroRecommendedWorkingSetUsesTheFallbackBudget() {
        let policy = RendererResourcePolicy(recommendedMaximumWorkingSetBytes: 0)

        #expect(policy.maximumWorkingSetBytes == 512 * 1024 * 1024)
    }
}
