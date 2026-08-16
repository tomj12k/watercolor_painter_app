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

    @Test func retainedRendererCheckpointsParticipateInCandidatePeakAdmission() throws {
        let exactPolicy = RendererResourcePolicy(maximumWorkingSetBytes: 5_484)

        let estimate = try exactPolicy.admit(
            width: 8,
            height: 4,
            layerCapacity: 2,
            structuralCandidateCapacity: 3,
            retainedCheckpointBytes: 100
        )

        #expect(estimate.retainedCheckpointBytes == 100)
        #expect(estimate.totalBytes == 5_484)

        let rejectingPolicy = RendererResourcePolicy(maximumWorkingSetBytes: 5_483)
        #expect(
            throws: RendererError.resourceBudgetExceeded(required: 5_484, available: 5_483)
        ) {
            try rejectingPolicy.admit(
                width: 8,
                height: 4,
                layerCapacity: 2,
                structuralCandidateCapacity: 3,
                retainedCheckpointBytes: 100
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

    @Test(arguments: [
        (recommended: UInt64(0), expected: 536_870_912),
        (recommended: UInt64(268_435_456), expected: 93_952_409),
        (recommended: UInt64(1_073_741_824), expected: 375_809_638),
        (recommended: UInt64(17_179_869_184), expected: 2_147_483_648)
    ])
    func liveBudgetUsesFallbackOnlyForAnUnavailableRecommendation(
        recommended: UInt64,
        expected: Int
    ) {
        let policy = RendererResourcePolicy(
            recommendedMaximumWorkingSetBytes: recommended
        )

        #expect(policy.maximumWorkingSetBytes == expected)
    }
}
