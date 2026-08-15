struct RendererWorkPolicy: Sendable {
    static let live = Self(
        maximumCommandThreads: 1_000_000_000,
        maximumProjectThreads: 2_000_000_000
    )

    let maximumCommandThreads: UInt64
    let maximumProjectThreads: UInt64

    init(maximumCommandThreads: UInt64, maximumProjectThreads: UInt64) {
        self.maximumCommandThreads = maximumCommandThreads
        self.maximumProjectThreads = maximumProjectThreads
    }

    func makeProjectBudget() -> RenderWorkBudget {
        RenderWorkBudget(
            maximumCommandThreads: maximumCommandThreads,
            maximumProjectThreads: maximumProjectThreads
        )
    }
}

struct RenderWorkBudget: Sendable {
    private let maximumCommandThreads: UInt64
    private let maximumProjectThreads: UInt64
    private var commandThreads: UInt64 = 0
    private var projectThreads: UInt64 = 0

    fileprivate init(maximumCommandThreads: UInt64, maximumProjectThreads: UInt64) {
        self.maximumCommandThreads = maximumCommandThreads
        self.maximumProjectThreads = maximumProjectThreads
    }

    mutating func beginCommand() {
        commandThreads = 0
    }

    mutating func consume(
        regionArea: Int,
        steps: Int,
        sliceDepth: Int,
        passCount: Int
    ) throws {
        let factors = [regionArea, steps, sliceDepth, passCount]
        var requiredThreads: UInt64 = 1
        for factor in factors {
            guard let factor = UInt64(exactly: factor) else {
                throw overflowError(available: maximumCommandThreads)
            }
            let (product, didOverflow) = requiredThreads.multipliedReportingOverflow(by: factor)
            guard !didOverflow else {
                throw overflowError(available: maximumCommandThreads)
            }
            requiredThreads = product
        }

        let (requiredCommandThreads, commandDidOverflow) = commandThreads
            .addingReportingOverflow(requiredThreads)
        guard !commandDidOverflow else {
            throw overflowError(available: maximumCommandThreads)
        }
        guard requiredCommandThreads <= maximumCommandThreads else {
            throw RendererError.workBudgetExceeded(
                required: requiredCommandThreads,
                available: maximumCommandThreads
            )
        }

        let (requiredProjectThreads, projectDidOverflow) = projectThreads
            .addingReportingOverflow(requiredThreads)
        guard !projectDidOverflow else {
            throw overflowError(available: maximumProjectThreads)
        }
        guard requiredProjectThreads <= maximumProjectThreads else {
            throw RendererError.workBudgetExceeded(
                required: requiredProjectThreads,
                available: maximumProjectThreads
            )
        }

        commandThreads = requiredCommandThreads
        projectThreads = requiredProjectThreads
    }

    private func overflowError(available: UInt64) -> RendererError {
        .workBudgetExceeded(required: .max, available: available)
    }
}
