import Testing
@testable import WatercolorEngine

@Suite struct RendererWorkPolicyTests {
    @Test func maximumCanvasAndDryStepsAreRejectedBeforeSubmission() throws {
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 1_000_000_000,
            maximumProjectThreads: 2_000_000_000
        )
        var budget = policy.makeProjectBudget()

        #expect(
            throws: RendererError.workBudgetExceeded(
                required: 137_438_953_472,
                available: 1_000_000_000
            )
        ) {
            try budget.consume(
                regionArea: 4096 * 4096,
                steps: 4096,
                sliceDepth: 1,
                passCount: 2
            )
        }
    }

    @Test func normalDryWorkFitsTheBudget() throws {
        let policy = RendererWorkPolicy.live
        var budget = policy.makeProjectBudget()

        try budget.consume(
            regionArea: 1600 * 1200,
            steps: 24,
            sliceDepth: 1,
            passCount: 2
        )
    }

    @Test func finiteSliceDepthIsIncludedInRequiredWork() {
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 59,
            maximumProjectThreads: 1_000
        )
        var budget = policy.makeProjectBudget()

        #expect(
            throws: RendererError.workBudgetExceeded(required: 60, available: 59)
        ) {
            try budget.consume(regionArea: 5, steps: 2, sliceDepth: 3, passCount: 2)
        }
    }

    @Test func oneCommandAccumulatesItsActualDispatches() throws {
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 100,
            maximumProjectThreads: 1_000
        )
        var budget = policy.makeProjectBudget()

        try budget.consume(regionArea: 3, steps: 10, sliceDepth: 1, passCount: 2)
        try budget.consume(regionArea: 2, steps: 10, sliceDepth: 1, passCount: 2)

        #expect(
            throws: RendererError.workBudgetExceeded(required: 102, available: 100)
        ) {
            try budget.consume(regionArea: 1, steps: 1, sliceDepth: 1, passCount: 2)
        }
    }

    @Test func replayCommandsShareTheProjectBudget() throws {
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 100,
            maximumProjectThreads: 150
        )
        var budget = policy.makeProjectBudget()
        try budget.consume(regionArea: 5, steps: 10, sliceDepth: 1, passCount: 2)

        budget.beginCommand()

        #expect(
            throws: RendererError.workBudgetExceeded(required: 160, available: 150)
        ) {
            try budget.consume(regionArea: 3, steps: 10, sliceDepth: 1, passCount: 2)
        }
    }

    @Test func overflowingThreadArithmeticIsRejected() {
        let policy = RendererWorkPolicy(
            maximumCommandThreads: .max,
            maximumProjectThreads: .max
        )
        var budget = policy.makeProjectBudget()

        #expect(
            throws: RendererError.workBudgetExceeded(required: .max, available: .max)
        ) {
            try budget.consume(
                regionArea: .max,
                steps: .max,
                sliceDepth: 2,
                passCount: 2
            )
        }
    }
}
