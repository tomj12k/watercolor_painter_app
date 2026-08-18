import Foundation
import Metal
import MetalKit
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite struct StudioFailureTests {
    @Test func resourceFailureExplainsRecoveryWithoutDocumentContent() {
        let diagnostic = StudioDiagnostic(
            appVersion: "1.2.3 (45)",
            operatingSystem: "macOS Test",
            gpuName: "Test GPU",
            canvasWidth: 4_096,
            canvasHeight: 2_048,
            layerCount: 3,
            commandCount: 9,
            errorCode: StudioFailure.Code.resourceBudget.rawValue
        )
        let failure = StudioFailure.resourceBudget(
            required: 3_000_000_000,
            available: 1_000_000_000,
            diagnostic: diagnostic
        )

        #expect(failure.code == .resourceBudget)
        #expect(failure.message.contains("painting is unchanged"))
        #expect(failure.recoverySuggestion.contains("Reduce the canvas size or layer count"))
        #expect(failure.diagnostic.customerText.contains("Error code: WC-RESOURCE-001"))
        #expect(failure.diagnostic.customerText.contains("Canvas: 4096 × 2048"))
        #expect(!failure.diagnostic.customerText.contains("Secret Layer Name"))
        #expect(!failure.diagnostic.customerText.contains("/Users/customer/Paintings"))
        #expect(!failure.message.contains("3000000000"))
        #expect(!failure.message.contains("1000000000"))
    }

    @Test func knownEngineAndDocumentFailuresHaveStableCustomerCategories() {
        let project = PaintingProject.newDefault()

        #expect(
            StudioFailure(error: RendererError.workBudgetExceeded(required: 101, available: 100), project: project).code
                == .workBudget
        )
        #expect(
            StudioFailure(error: RendererError.metalUnavailable, project: project).code
                == .metalUnavailable
        )
        #expect(
            StudioFailure(error: DocumentCodecError.malformedData, project: project).code
                == .malformedDocument
        )
        #expect(
            StudioFailure(error: DocumentCodecError.unsupportedSchema(99), project: project).code
                == .newerDocument
        )
    }

    @Test @MainActor func eachToolRemembersItsOwnSettings() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )

        // The brush keeps its pigment defaults.
        #expect(model.brush.opacity == BrushSettings.default.opacity)
        model.setBrushSize(120)

        // Strength tools start at full strength, matching how they always
        // behaved before strength became adjustable.
        model.selectedTool = .eraser
        #expect(model.brush.opacity == 1)
        model.setBrushSize(60)

        // Each tool's changes survive switching away and back.
        model.selectedTool = .water
        model.selectedTool = .eraser
        #expect(model.brush.size == 60)
        model.selectedTool = .brush
        #expect(model.brush.size == 120)
        #expect(model.brush.opacity == BrushSettings.default.opacity)

        // Every non-brush tool carries full default strength.
        for tool in [PaintTool.smudge, .smear, .dry] {
            model.selectedTool = tool
            #expect(model.brush.opacity == 1, "tool \(tool) should default to full strength")
        }

        // New strokes carry the strength-capable behavior version.
        #expect(model.brush.behaviorVersion == 2)
    }

    @Test @MainActor func previewDrainSizeAlignsWithTheRendererStampBatchStride() {
        // Wet simulation runs between stamp batches. A drain size off the
        // batch stride would shift batch boundaries between live preview
        // and replay, so live pixels would diverge from reopen.
        #expect(StudioModel.previewPointDrainLimit % WatercolorRenderer.stampBatchSize == 0)
        #expect(StudioModel.previewPointDrainLimit > 0)
    }

    @Test @MainActor func routineLimitsRaiseANoticeInsteadOfAModalError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumCommandCount = 2
        var project = PaintingProject.studioTestProject()
        project.commands = (0..<maximumCommandCount).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: maximumCommandCount,
                maximumTotalStrokePointCount: 128,
                maximumSerializedStorageBytes: 1_048_576
            ),
            debugCommandBufferError: { $0.error }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            maximumCommandCount: maximumCommandCount,
            maximumTotalStrokePointCount: 128,
            maximumSerializedStorageBytes: 1_048_576
        )

        // A stroke refused at a document limit is a routine event: it must
        // inform without interrupting, so it may never raise a modal alert.
        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))
        #expect(model.error == nil)
        #expect(model.notice?.message.contains("command capacity") == true)
        #expect(model.notice?.code == .capacity)

        // A capacity-ended-but-saved stroke and dropped queued strokes are
        // the same kind of event.
        model.dismissNotice()
        #expect(model.notice == nil)
        model.noteStrokeExhaustion(.pointCapacity(maximumPointCount: 2))
        #expect(model.error == nil)
        #expect(model.notice?.message.contains("ended and saved") == true)

        model.noteDroppedDeferredStrokes(count: 2)
        #expect(model.error == nil)
        #expect(model.notice?.message.contains("could not be painted") == true)
    }

    @Test @MainActor func capacityLimitsCarryTheCapacityCategoryAndAccurateRecovery() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumCommandCount = 2
        var project = PaintingProject.studioTestProject()
        project.commands = (0..<maximumCommandCount).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: maximumCommandCount,
                maximumTotalStrokePointCount: 128,
                maximumSerializedStorageBytes: 1_048_576
            ),
            debugCommandBufferError: { $0.error }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            maximumCommandCount: maximumCommandCount,
            maximumTotalStrokePointCount: 128,
            maximumSerializedStorageBytes: 1_048_576
        )

        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))

        let failure = try #require(model.notice)
        #expect(failure.message.contains("command capacity"))
        #expect(failure.code.rawValue == "WC-CAPACITY-001")
        #expect(!failure.recoverySuggestion.contains("Try the operation again"))
        #expect(failure.recoverySuggestion.contains("Undo"))
        #expect(failure.diagnostic.errorCode == "WC-CAPACITY-001")
        #expect(failure.diagnostic.canvasWidth == project.canvas.width)
        #expect(failure.diagnostic.commandCount == project.commands.count)

        let storageProject = PaintingProject.studioTestProject()
        let storageModel = StudioModel(
            project: storageProject,
            renderer: try WatercolorRenderer(project: storageProject, device: device),
            maximumSerializedStorageBytes: 6_000
        )
        storageModel.completeStroke(.studioTestStroke(layerID: storageProject.layers[0].id))
        let storageFailure = try #require(storageModel.notice)
        #expect(storageFailure.message.contains("document storage capacity"))
        #expect(storageFailure.code.rawValue == "WC-CAPACITY-001")
        #expect(!storageFailure.recoverySuggestion.contains("Try the operation again"))

        let pointProject = PaintingProject.studioPointCapacityProject(pointCount: 3)
        let pointModel = StudioModel(
            project: pointProject,
            renderer: try WatercolorRenderer(
                project: pointProject,
                device: device,
                debugProjectAdmissionLimits: ProjectAdmissionLimits(
                    maximumCommandCount: 8,
                    maximumTotalStrokePointCount: 4,
                    maximumSerializedStorageBytes: 1_048_576
                ),
                debugCommandBufferError: { $0.error }
            ),
            maximumCommandCount: 8,
            maximumTotalStrokePointCount: 4,
            maximumSerializedStorageBytes: 1_048_576
        )
        var pointStroke = StrokeCommand.studioTestStroke(layerID: pointProject.layers[0].id)
        pointStroke.points.append(
            StrokePoint(x: 129, y: 128, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )
        pointModel.completeStroke(pointStroke)
        let pointFailure = try #require(pointModel.notice)
        #expect(pointFailure.message.contains("point capacity"))
        #expect(pointFailure.code.rawValue == "WC-CAPACITY-001")
        #expect(!pointFailure.recoverySuggestion.contains("Try the operation again"))
    }

    @Test @MainActor func capacityWarningAppearsAtNinetyPercentAndNamesTheAction() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumCommandCount = 10
        let limits = ProjectAdmissionLimits(
            maximumCommandCount: maximumCommandCount,
            maximumTotalStrokePointCount: 1_024,
            maximumSerializedStorageBytes: 8_388_608
        )
        var project = PaintingProject.studioTestProject()
        project.commands = (0..<8).map { _ in
            .clearLayer(LayerCommand(layerID: project.layers[0].id))
        }
        func makeModel(_ project: PaintingProject) throws -> StudioModel {
            StudioModel(
                project: project,
                renderer: try WatercolorRenderer(
                    project: project,
                    device: device,
                    debugProjectAdmissionLimits: limits,
                    debugCommandBufferError: { $0.error }
                ),
                maximumCommandCount: maximumCommandCount,
                maximumTotalStrokePointCount: 1_024,
                maximumSerializedStorageBytes: 8_388_608
            )
        }

        // Below the threshold, no warning distracts from painting.
        let model = try makeModel(project)
        #expect(model.capacityWarning == nil)

        // At nine of ten commands the indicator appears and names the action.
        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))
        let warning = try #require(model.capacityWarning)
        #expect(warning.contains("90%"))
        #expect(warning.contains("new document"))

        // Painting the final command moves the indicator to one hundred percent.
        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id, x: 96))
        #expect(model.project.commands.count == maximumCommandCount)
        #expect(model.capacityWarning?.contains("100%") == true)

        // Undoing history clears the warning again.
        model.undo()
        model.undo()
        #expect(model.project.commands.count == 8)
        #expect(model.capacityWarning == nil)
    }

    @Test @MainActor func strokeExhaustionNoticeUsesTheCapacityCategoryWithItsOwnRecovery() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )

        model.noteStrokeExhaustion(.pointCapacity(maximumPointCount: 12))

        let failure = try #require(model.notice)
        #expect(failure.message == "This stroke reached its 12-point limit, so Watercolor Studio ended and saved it there.")
        #expect(failure.recoverySuggestion == "Start a new stroke to keep painting.")
        #expect(failure.code.rawValue == "WC-CAPACITY-001")
        #expect(failure.diagnostic.canvasWidth == project.canvas.width)
    }

    @Test func unknownFailureDoesNotExposeRawPathsOrIdentifiers() {
        let raw = NSError(
            domain: "SensitiveSubsystem",
            code: 71,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "failed /Users/customer/Secret.watercolor layer 98A8D770-96B3-4E4C-987A-7915F093B583"
            ]
        )
        let failure = StudioFailure(error: raw, project: PaintingProject.newDefault())

        #expect(failure.code == .unknown)
        #expect(!failure.message.contains("/Users/customer"))
        #expect(!failure.message.contains("98A8D770"))
        #expect(!failure.diagnostic.customerText.contains("/Users/customer"))
        #expect(!failure.diagnostic.customerText.contains("98A8D770"))
    }
}

@Suite @MainActor struct StudioModelTests {
    @Test func initialStateReflectsTheProjectAndStudioDefaults() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)

        let model = StudioModel(project: project, renderer: renderer)

        #expect(model.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.selectedTool == .brush)
        #expect(model.brush == .default)
        #expect(model.zoom == 1)
        #expect(model.pan == .zero)
        #expect(model.error == nil)
        #expect(model.capabilities == StudioCapabilities(canPaint: true, canUndo: false, canRedo: false))
    }

    @Test func completedStrokeUpdatesProjectDocumentAndCapabilities() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)

        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(model.error == nil)
    }

    @Test func commandCapacityIsCheckedBeforeRendering() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumCommandCount = 2
        var project = PaintingProject.studioTestProject()
        project.commands = (0..<maximumCommandCount).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: maximumCommandCount,
                maximumTotalStrokePointCount: 128,
                maximumSerializedStorageBytes: 1_048_576
            ),
            debugCommandBufferError: { $0.error }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            maximumCommandCount: maximumCommandCount,
            maximumTotalStrokePointCount: 128,
            maximumSerializedStorageBytes: 1_048_576
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()

        model.beginStrokePreview(stroke)

        #expect(!model.isStrokePreviewActive)
        #expect(model.project.commands.count == maximumCommandCount)
        #expect(model.rendererProject.commands.count == maximumCommandCount)
        #expect(documentUpdates.isEmpty)
        #expect(model.notice?.message.contains("2") == true)
        #expect(try renderer.studioChecksum() == checksumBefore)

        model.completeStroke(stroke)

        #expect(model.project.commands.count == maximumCommandCount)
        #expect(model.rendererProject.commands.count == maximumCommandCount)
        #expect(documentUpdates.isEmpty)
        #expect(model.notice?.message.contains("2") == true)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func aggregatePointCapacityIsCheckedBeforeSynchronousRendering() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumTotalStrokePointCount = 4
        let project = PaintingProject.studioPointCapacityProject(pointCount: 3)
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: 8,
                maximumTotalStrokePointCount: maximumTotalStrokePointCount,
                maximumSerializedStorageBytes: 1_048_576
            ),
            debugCommandBufferError: { $0.error }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            maximumCommandCount: 8,
            maximumTotalStrokePointCount: maximumTotalStrokePointCount,
            maximumSerializedStorageBytes: 1_048_576
        )
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        stroke.points.append(StrokePoint(x: 129, y: 128, pressure: 1, tiltX: 0, tiltY: 0, time: 1))
        let checksumBefore = try renderer.studioChecksum()

        model.completeStroke(stroke)

        #expect(model.project.commands.count == project.commands.count)
        #expect(model.rendererProject.commands.count == project.commands.count)
        #expect(documentUpdates.isEmpty)
        #expect(model.notice?.message.contains("point capacity") == true)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func serializedStorageCapacityIsCheckedBeforeEveryStrokeMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            maximumSerializedStorageBytes: 6_000
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()

        #expect(model.beginStrokePreview(stroke) == .unavailable)
        #expect(model.notice?.message.contains("document storage capacity") == true)
        #expect(!model.isStrokePreviewActive)

        model.completeStroke(stroke)

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(documentUpdates.isEmpty)
        #expect(model.notice?.message.contains("document storage capacity") == true)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func directStrokeUsesAtomicRendererAdmissionBeforeSubmission() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        var strokeSubmissions = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: 4,
                maximumTotalStrokePointCount: 8,
                maximumSerializedStorageBytes: 6_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor stroke" {
                    strokeSubmissions += 1
                }
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()

        model.completeStroke(stroke)

        #expect(strokeSubmissions == 0)
        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(try renderer.studioChecksum() == checksumBefore)
        #expect(model.error?.code == .malformedDocument)
    }

    @Test func invalidStrokeValidationNeverExposesItsCommandIdentifier() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let sentinel = UUID(uuidString: "A93E0D96-6D71-43C5-9E9D-75D1260C80AD")!
        var project = PaintingProject.studioTestProject()
        project.commands = [
            .stroke(.studioTestStroke(id: sentinel, layerID: project.layers[0].id))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let duplicate = StrokeCommand.studioTestStroke(
            id: sentinel,
            layerID: project.layers[0].id,
            x: 96,
            y: 96
        )

        model.completeStroke(duplicate)

        #expect(model.project == project)
        #expect(model.error?.code == .malformedDocument)
        #expect(model.error?.message.contains(sentinel.uuidString) == false)
        #expect(model.error?.diagnostic.customerText.contains(sentinel.uuidString) == false)
    }

    @Test func previewCommitRechecksAggregatePointCapacityAfterAwaitingUpdates() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let maximumTotalStrokePointCount = 10
        let project = PaintingProject.studioPointCapacityProject(pointCount: 3)
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: ProjectAdmissionLimits(
                maximumCommandCount: 8,
                maximumTotalStrokePointCount: maximumTotalStrokePointCount,
                maximumSerializedStorageBytes: 1_048_576
            ),
            debugCommandBufferError: { $0.error }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            maximumCommandCount: 8,
            maximumTotalStrokePointCount: maximumTotalStrokePointCount,
            maximumSerializedStorageBytes: 1_048_576
        )
        var finalStroke = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 64,
            y: 64
        )
        finalStroke.points = (0..<8).map { index in
            StrokePoint(
                x: Double(64 + index * 8),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var preview = finalStroke
        preview.points = [finalStroke.points[0]]
        let checksumBefore = try renderer.studioChecksum()
        let synchronousReplayCountBefore = renderer.debugSynchronousReplaySubmissionCount

        model.beginStrokePreview(preview)
        model.appendStrokePreview(
            id: preview.id,
            points: Array(finalStroke.points.dropFirst())
        )
        await model.waitForStrokePreviewIdle()
        #expect(model.isStrokePreviewActive)

        await model.commitStrokePreview(finalStroke)

        #expect(!model.isStrokePreviewActive)
        #expect(
            renderer.debugSynchronousReplaySubmissionCount
                == synchronousReplayCountBefore
        )
        #expect(renderer.debugSynchronousPreviewCancellationWaitCount == 0)
        #expect(renderer.debugSynchronousPreviewCancellationReplayCount == 0)
        #expect(model.project.commands.count == project.commands.count)
        #expect(model.rendererProject.commands.count == project.commands.count)
        #expect(documentUpdates.isEmpty)
        #expect(model.notice?.message.contains("point capacity") == true)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func liveStrokePreviewRendersDuringDragAndCommitsExactlyOneCommand() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var updates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { updates.append($0) }
        )
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id, x: 64, y: 64)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 2),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.waitForStrokePreviewIdle()
        #expect(model.isStrokePreviewActive)
        #expect(model.project.commands.isEmpty)
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha > 0.05)

        let secondBatch: [StrokePoint] = (9..<17).map { index in
            let x = Double(index * 4 + 48)
            let time = Double(index) / 60
            return StrokePoint(
                x: x,
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: time
            )
        }
        stroke.points.append(contentsOf: secondBatch)
        model.appendStrokePreview(id: stroke.id, points: secondBatch)
        await model.waitForStrokePreviewIdle()
        #expect(model.project.commands.isEmpty)
        #expect(try renderer.debugPixel(x: 96, y: 64).alpha > 0.05)

        await model.commitStrokePreview(stroke)

        #expect(!model.isStrokePreviewActive)
        #expect(model.project.commands == [.stroke(stroke)])
        #expect(model.rendererProject.commands == [.stroke(stroke)])
        #expect(updates == [model.project])
    }

    @Test func queuedPreviewPointsDrainInAdaptiveBoundedSubmissions() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var submittedPointCounts: [Int] = []
        let operation = StrokePreviewRendererOperation(
            update: { _, _, points, _ in
                submittedPointCounts.append(points.count)
            },
            finish: { _, _, _ in }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: operation
        )
        let stroke = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 48,
            y: 96
        )
        #expect(model.beginStrokePreview(stroke) == .accepted)

        // A queued backlog drains in one submission, so paint catches up to
        // the cursor instead of trickling out eight points per GPU round-trip.
        let queuedPoints: [StrokePoint] = (1...33).map { (index: Int) -> StrokePoint in
            let x = Double(48 + index * 3)
            let y = Double(96 + (index % 5) * 2)
            let time = Double(index) / 120
            return StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: time)
        }
        model.appendStrokePreview(id: stroke.id, points: queuedPoints)
        await model.waitForStrokePreviewIdle()

        #expect(submittedPointCounts == [33])
        #expect(model.error == nil)

        // An extreme backlog is still bounded per submission, so cancellation
        // never waits behind one enormous in-flight append.
        let hugeBacklog: [StrokePoint] = (34...400).map { (index: Int) -> StrokePoint in
            let x = Double(48 + (index % 100) * 3)
            let y = Double(96 + (index % 5) * 2)
            let time = Double(index) / 120
            return StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: time)
        }
        submittedPointCounts = []
        model.appendStrokePreview(id: stroke.id, points: hugeBacklog)
        await model.waitForStrokePreviewIdle()

        #expect(submittedPointCounts == [64, 64, 64, 64, 64, 47])
        #expect(model.error == nil)
    }

    @Test func longQueuedScribbleStaysWithinTheRendererWorkBudget() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.canvas = CanvasSize(width: 1_600, height: 1_200)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var stroke = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 24,
            y: 48
        )
        let scribbleIndices: [Int] = Array(1...120)
        let scribblePoints: [StrokePoint] = scribbleIndices.map { index in
            StrokePoint(
                x: Double(24 + (index % 32) * 48),
                y: Double(48 + ((index * 17) % 24) * 48),
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }
        stroke.points.append(contentsOf: scribblePoints)
        var initial = stroke
        initial.points = [stroke.points[0]]

        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()

        #expect(model.error == nil)
        #expect(model.isStrokePreviewActive)
        await model.commitStrokePreview(stroke)

        #expect(model.error == nil)
        #expect(model.project.commands == [.stroke(stroke)])
        let replayed = try WatercolorRenderer(project: model.project, device: device)
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func largeQueuedPreviewUsesIndexedStorageCompaction() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var submittedPointCounts: [Int] = []
        let operation = StrokePreviewRendererOperation(
            update: { _, _, points, _ in
                submittedPointCounts.append(points.count)
            },
            finish: { _, _, _ in }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: operation
        )
        let stroke = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 48,
            y: 96
        )
        #expect(model.beginStrokePreview(stroke) == .accepted)

        let indices: [Int] = Array(1...4_096)
        let queuedPoints: [StrokePoint] = indices.map { index in
            StrokePoint(
                x: Double(48 + (index % 64) * 2),
                y: Double(96 + ((index * 13) % 64) * 2),
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 120
            )
        }
        model.appendStrokePreview(id: stroke.id, points: queuedPoints)
        await model.waitForStrokePreviewIdle()

        #expect(submittedPointCounts.count == 64)
        #expect(submittedPointCounts.allSatisfy { $0 == StudioModel.previewPointDrainLimit })
        #expect(model.pendingStrokePreviewPointCountForTesting == 0)
        #expect(model.pendingStrokePreviewCompactionCountForTesting == 1)
        #expect(model.error == nil)
    }

    @Test func multiUpdatePreviewCommitExactlyMatchesFreshSemanticReplay() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var completeStroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "F7EDEAC6-20C3-45AA-8DC3-9796425789B4")!,
            layerID: project.layers[0].id,
            x: 48,
            y: 96
        )
        completeStroke.points = (0..<17).map { index -> StrokePoint in
            let x = Double(48 + index * 9)
            let y = Double(96 + (index % 4) * 7)
            let pressure = 0.45 + Double(index % 3) * 0.2
            let time = Double(index) / 60.0
            return StrokePoint(x: x, y: y, pressure: pressure, tiltX: 0, tiltY: 0, time: time)
        }

        var initial = completeStroke
        initial.points = [completeStroke.points[0]]
        model.beginStrokePreview(initial)
        var submittedPointCount = 1
        for pointCount in [3, 9, 17] {
            model.appendStrokePreview(
                id: completeStroke.id,
                points: Array(completeStroke.points[submittedPointCount..<pointCount])
            )
            submittedPointCount = pointCount
        }
        await model.commitStrokePreview(completeStroke)

        let replayed = try WatercolorRenderer(project: model.project, device: device)
        #expect(model.project.commands == [.stroke(completeStroke)])
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func previewsOnNewlySelectedLayersReuseRendererSnapshots() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.layers.append(PaintLayer(name: "Second"))
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let snapshots = renderer.debugResources.previewTextures

        for (index, layer) in project.layers.enumerated() {
            model.selectedLayerID = layer.id
            let stroke = StrokeCommand.studioTestStroke(
                layerID: layer.id,
                x: Double(64 + index * 64),
                y: 128
            )
            model.beginStrokePreview(stroke)
            await model.commitStrokePreview(stroke)
            #expect(renderer.debugResources.previewTextures == snapshots)
        }

        let replayed = try WatercolorRenderer(project: model.project, device: device)
        #expect(renderer.debugResources.previewTextureAllocationCount == 2)
        #expect(renderer.debugResources.previewArrayLength == 1)
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func wetNonSelectedLayerEvolutionMatchesReplayAcrossPreviewCommit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let wet = PaintLayer(name: "Wet")
        let selected = PaintLayer(name: "Selected")
        var project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [wet, selected]
        )
        project.commands = [.stroke(.studioTestStroke(layerID: wet.id, x: 64, y: 64))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.selectedLayerID = selected.id
        let wetnessBefore = try renderer.debugWetness(x: 64, y: 64, layerID: wet.id)
        var preview = StrokeCommand.studioTestStroke(layerID: selected.id, x: 112, y: 160)
        preview.points = (0..<9).map { index in
            StrokePoint(
                x: Double(112 + index * 8),
                y: 160,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = preview
        initial.points = [preview.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: preview.id, points: Array(preview.points[1...]))
        await model.waitForStrokePreviewIdle()
        let previewChecksum = try renderer.studioChecksum()
        let previewWetness = try renderer.debugWetness(x: 64, y: 64, layerID: wet.id)

        #expect(previewWetness < wetnessBefore)
        await model.commitStrokePreview(preview)
        let replayed = try WatercolorRenderer(project: model.project, device: device)
        let finishedWetness = try renderer.debugWetness(x: 64, y: 64, layerID: wet.id)

        #expect(try renderer.studioChecksum() != previewChecksum)
        #expect(finishedWetness < previewWetness)
        #expect(
            finishedWetness
                == (try replayed.debugWetness(x: 64, y: 64, layerID: wet.id))
        )
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func rapidMouseStyleUpdatesCoalesceGPUPreviewWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.canvas = CanvasSize(width: 1_600, height: 1_200)
        let previewSubmissions = CommandBufferLabelCounter(label: "Watercolor stroke preview")
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                previewSubmissions.record(commandBuffer.label)
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        var stroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "31C771C7-B8A6-48AC-995A-F7C2C468BA93")!,
            layerID: project.layers[0].id,
            x: 24,
            y: 72
        )

        model.beginStrokePreview(stroke)
        for index in 1..<24 {
            let point = StrokePoint(
                x: Double(24 + index * 6),
                y: Double(72 + index % 3),
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 120
            )
            stroke.points.append(point)
            model.appendStrokePreview(id: stroke.id, points: [point])
        }
        await model.commitStrokePreview(stroke)

        let replayed = try WatercolorRenderer(project: model.project, device: device)
        #expect(previewSubmissions.count <= 3)
        #expect(model.project.commands == [.stroke(stroke)])
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func rapidUpdatesQueueOnlyUnsubmittedPointDeltas() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let suspension = ControlledPreviewSuspension()
        var submittedBatches: [[StrokePoint]] = []
        let operation = StrokePreviewRendererOperation(
            update: { renderer, id, points, token in
                submittedBatches.append(points)
                _ = try await suspension.suspendOnce()
                try await renderer.appendStrokePreview(id: id, points: points, token: token)
            },
            finish: { renderer, stroke, token in
                try await renderer.finishStrokePreview(stroke, token: token)
            }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: operation
        )
        let initial = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "92540642-34B4-463D-B103-9625A7F8FFB8")!,
            layerID: project.layers[0].id,
            x: 32,
            y: 96
        )
        let firstBatch = (1...3).map { index in
            StrokePoint(
                x: Double(32 + index * 8), y: 96, pressure: 1,
                tiltX: 0, tiltY: 0, time: Double(index)
            )
        }
        let secondBatch = (4...6).map { index in
            StrokePoint(
                x: Double(32 + index * 8), y: 96, pressure: 1,
                tiltX: 0, tiltY: 0, time: Double(index)
            )
        }
        let thirdBatch = (7...10).map { index in
            StrokePoint(
                x: Double(32 + index * 8), y: 96, pressure: 1,
                tiltX: 0, tiltY: 0, time: Double(index)
            )
        }
        var complete = initial
        complete.points.append(contentsOf: firstBatch + secondBatch + thirdBatch)

        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: initial.id, points: firstBatch)
        await suspension.waitUntilSuspended()
        model.appendStrokePreview(id: initial.id, points: secondBatch)
        model.appendStrokePreview(id: initial.id, points: thirdBatch)

        #expect(model.pendingStrokePreviewPointCountForTesting == 7)

        await suspension.resume()
        await model.commitStrokePreview(complete)

        #expect(submittedBatches == [firstBatch, secondBatch + thirdBatch])
        #expect(model.pendingStrokePreviewPointCountForTesting == 0)
        let replayed = try WatercolorRenderer(project: model.project, device: device)
        #expect(try renderer.studioChecksum() == replayed.studioChecksum())
    }

    @Test func livePreviewUpdateProcessesOnlyNewMousePoints() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.canvas = CanvasSize(width: 1_600, height: 1_200)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var stroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "EA7F7A56-E65E-4FCB-A530-54215C5F72F4")!,
            layerID: project.layers[0].id,
            x: 100,
            y: 400
        )
        stroke.points = (0..<32).map { index in
            StrokePoint(
                x: Double(100 + index * 8),
                y: 400,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 120
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.waitForStrokePreviewIdle()
        let appendedPoints = (32..<40).map { index in
            StrokePoint(
                x: Double(100 + index * 8),
                y: 400,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 120
            )
        }
        stroke.points.append(contentsOf: appendedPoints)
        model.appendStrokePreview(id: stroke.id, points: appendedPoints)
        await model.waitForStrokePreviewIdle()

        #expect(renderer.debugLastStrokeDispatch.stampBatchCount == 1)
        #expect(renderer.debugLastStrokeDispatch.simulationStepCount == 16)
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
    }

    @Test func cancellingLiveStrokePreviewRestoresTheCommittedRaster() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let before = try renderer.studioChecksum()

        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id, x: 64, y: 64)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 2),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }
        var initial = stroke
        initial.points = [stroke.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.waitForStrokePreviewIdle()
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha > 0.05)

        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()

        #expect(!model.isStrokePreviewActive)
        #expect(model.project.commands.isEmpty)
        #expect(try renderer.studioChecksum() == before)
    }

    @Test func cancellationRestorationKeepsTheMainActorSchedulable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let cancellation = ControlledPreviewSuspension()
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                },
                cancel: { renderer, token in
                    _ = try await cancellation.suspendOnce()
                    try await renderer.restoreStrokePreviewCancellation(token)
                }
            )
        )
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 8),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = stroke
        initial.points = [stroke.points[0]]
        let checksumBefore = try renderer.studioChecksum()
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()

        model.cancelStrokePreview()
        await cancellation.waitUntilSuspended()
        #expect(!model.capabilities.canPaint)
        #expect(
            model.beginStrokePreview(StrokeCommand.studioTestStroke(
                layerID: project.layers[0].id
            ))
                == .busy
        )

        var heartbeatRan = false
        let heartbeat = Task { @MainActor in
            heartbeatRan = true
            await cancellation.resume()
        }
        await model.waitForStrokePreviewCancellation()
        await heartbeat.value

        #expect(heartbeatRan)
        #expect(!model.isStrokePreviewActive)
        #expect(model.capabilities.canPaint)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func failedLiveStrokePreviewNeverCommitsAndRollsBack() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "live preview failed"]
        )
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                commandBuffer.label == "Watercolor stroke preview" ? injectedError : commandBuffer.error
            }
        )
        var updates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { updates.append($0) }
        )
        let before = try renderer.studioChecksum()
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id, x: 64, y: 64)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 2),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.commitStrokePreview(stroke)
        await model.waitForStrokePreviewCancellation()

        #expect(!model.isStrokePreviewActive)
        #expect(model.project.commands.isEmpty)
        #expect(model.rendererProject.commands.isEmpty)
        #expect(updates.isEmpty)
        #expect(model.error?.code == .gpuExecution)
        #expect(try renderer.studioChecksum() == before)
    }

    @Test func previewCancelCannotCommitAfterSuspendedFinish() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let finish = ControlledPreviewSuspension()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    _ = try await finish.suspendOnce()
                }
            )
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()
        let synchronousReplayCountBefore = renderer.debugSynchronousReplaySubmissionCount

        #expect(model.beginStrokePreview(stroke) == .accepted)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(stroke)
        }
        await finish.waitUntilSuspended()

        #expect(!model.capabilities.canPaint)
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(try renderer.studioChecksum() == checksumBefore)

        await finish.resume()
        await commit.value

        #expect(
            renderer.debugSynchronousReplaySubmissionCount
                == synchronousReplayCountBefore
        )
        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(documentUpdates.isEmpty)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func rendererChangingEditsAreRejectedWhilePreviewOwnsRenderer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let finish = ControlledPreviewSuspension()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    _ = try await finish.suspendOnce()
                }
            )
        )
        let existing = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 64,
            y: 64
        )
        let preview = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 192,
            y: 192
        )
        model.completeStroke(existing)
        let committedProject = model.project
        let owningRendererIdentity = model.rendererIdentity

        #expect(model.beginStrokePreview(preview) == .accepted)
        #expect(!model.capabilities.canUndo)
        #expect(!model.canAddLayer)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(preview)
        }
        await finish.waitUntilSuspended()

        model.undo()
        model.addLayer()

        #expect(model.project == committedProject)
        #expect(model.rendererIdentity == owningRendererIdentity)
        #expect(documentUpdates == [committedProject])

        await finish.resume()
        await commit.value

        let reopened = try WatercolorRenderer(project: model.project, device: device)
        #expect(model.project.commands == [.stroke(existing), .stroke(preview)])
        #expect(model.rendererProject == model.project)
        #expect(model.rendererIdentity == owningRendererIdentity)
        #expect(documentUpdates == [committedProject, model.project])
        #expect(try renderer.studioChecksum() == reopened.studioChecksum())
    }

    @Test func staleUpdateFailureCannotCancelAReusedStrokeIDGeneration() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let update = ControlledPreviewSuspension()
        let secondUpdateCompleted = ControlledPreviewSignal()
        let operation = StrokePreviewRendererOperation(
            update: { renderer, id, points, token in
                let wasSuspended = try await update.suspendOnce()
                try await renderer.appendStrokePreview(id: id, points: points, token: token)
                if !wasSuspended {
                    await secondUpdateCompleted.signal()
                }
            },
            finish: { renderer, stroke, token in
                try await renderer.finishStrokePreview(stroke, token: token)
            }
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: operation
        )
        let reusedID = UUID(uuidString: "13400374-15FD-45EE-958D-3B9BB767281A")!
        var first = StrokeCommand.studioTestStroke(
            id: reusedID,
            layerID: project.layers[0].id,
            x: 64,
            y: 64
        )
        var second = StrokeCommand.studioTestStroke(
            id: reusedID,
            layerID: project.layers[0].id,
            x: 192,
            y: 192
        )

        let firstPoint = StrokePoint(
            x: 72, y: 64, pressure: 1, tiltX: 0, tiltY: 0, time: 1
        )
        first.points.append(firstPoint)
        var firstInitial = first
        firstInitial.points = [first.points[0]]
        #expect(model.beginStrokePreview(firstInitial) == .accepted)
        model.appendStrokePreview(id: first.id, points: [firstPoint])
        let firstCommit = Task { @MainActor in
            await model.commitStrokePreview(first)
        }
        await update.waitUntilSuspended()
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
        let secondPoint = StrokePoint(
            x: 200, y: 192, pressure: 1, tiltX: 0, tiltY: 0, time: 1
        )
        second.points.append(secondPoint)
        var secondInitial = second
        secondInitial.points = [second.points[0]]
        #expect(model.beginStrokePreview(secondInitial) == .accepted)
        model.appendStrokePreview(id: second.id, points: [secondPoint])
        await secondUpdateCompleted.wait()
        #expect(model.pendingStrokePreviewPointCountForTesting == 0)

        await update.resume()
        await firstCommit.value

        #expect(model.isStrokePreviewActive)
        #expect(model.error == nil)
        #expect(model.pendingStrokePreviewPointCountForTesting == 0)
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
    }

    @Test func failedPreviewRestorationDisablesPaintingUntilRendererRebuild() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 43,
            userInfo: [NSLocalizedDescriptionKey: "preview restoration failed"]
        )
        var shouldFailReplay = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailReplay, commandBuffer.label == "Watercolor replay" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let finish = ControlledPreviewSuspension()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    _ = try await finish.suspendOnce()
                }
            )
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)

        #expect(model.beginStrokePreview(stroke) == .accepted)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(stroke)
        }
        await finish.waitUntilSuspended()
        shouldFailReplay = true

        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canPaint)
        #expect(model.rendererRecoveryError != nil)
        // One report per failure: the recovery banner owns the message and
        // the Try Again control, so no modal alert may appear on top of it.
        #expect(model.error == nil)
        #expect(
            model.beginStrokePreview(.studioTestStroke(layerID: project.layers[0].id))
                == .unavailable
        )

        shouldFailReplay = false
        await finish.resume()
        await commit.value
        model.addLayer()

        #expect(model.rendererRecoveryError == nil)
        #expect(model.capabilities.canPaint)
        #expect(model.rendererCheckpointCountForTesting == 0)
    }

    @Test func retryRendererRecoveryRestoresPaintingWithoutAStructuralEdit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 47,
            userInfo: [NSLocalizedDescriptionKey: "preview restoration failed"]
        )
        var shouldFailReplay = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailReplay, commandBuffer.label == "Watercolor replay" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let finish = ControlledPreviewSuspension()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) },
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    _ = try await finish.suspendOnce()
                }
            )
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)

        #expect(model.beginStrokePreview(stroke) == .accepted)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(stroke)
        }
        await finish.waitUntilSuspended()
        shouldFailReplay = true
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()
        await finish.resume()
        await commit.value
        #expect(model.rendererRecoveryError != nil)
        #expect(!model.capabilities.canPaint)

        // A retry that fails keeps the recovery state and reports why.
        model.retryRendererRecovery()
        #expect(model.rendererRecoveryError != nil)
        #expect(!model.capabilities.canPaint)
        #expect(model.error != nil)

        // A retry that succeeds restores painting without a structural edit.
        shouldFailReplay = false
        model.retryRendererRecovery()
        #expect(model.rendererRecoveryError == nil)
        #expect(model.capabilities.canPaint)
        #expect(model.error == nil)
        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)

        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))
        #expect(model.project.commands.count == 1)
        #expect(model.error == nil)
    }

    @Test func failedPreviewCancellationRestoreDisablesPainting() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 44,
            userInfo: [NSLocalizedDescriptionKey: "preview cancellation restore failed"]
        )
        var shouldFailCancellation = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailCancellation,
                   commandBuffer.label == "Cancel watercolor stroke preview" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 8),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.waitForStrokePreviewIdle()
        shouldFailCancellation = true

        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()

        #expect(model.project == project)
        #expect(model.rendererRecoveryError != nil)
        #expect(!model.capabilities.canPaint)
    }

    @Test func failedPreviewFinishRestorationDisablesPainting() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 45,
            userInfo: [NSLocalizedDescriptionKey: "preview finish restoration failed"]
        )
        var shouldFailFinish = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailFinish,
                   commandBuffer.label == "Commit watercolor stroke preview"
                    || commandBuffer.label == "Cancel watercolor stroke preview" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        var stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        stroke.points = (0..<9).map { index in
            StrokePoint(
                x: Double(64 + index * 8),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points[1...]))
        await model.waitForStrokePreviewIdle()
        shouldFailFinish = true

        await model.commitStrokePreview(stroke)

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(model.rendererRecoveryError != nil)
        #expect(!model.capabilities.canPaint)
    }

    @Test func finishFailureBeforeRendererCommitRestoresTheTransactionAsynchronously() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 46,
            userInfo: [NSLocalizedDescriptionKey: "finish rejected before renderer commit"]
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { _, _, _ in
                    throw injectedError
                }
            )
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()
        let synchronousReplayCountBefore = renderer.debugSynchronousReplaySubmissionCount

        #expect(model.beginStrokePreview(stroke) == .accepted)
        await model.commitStrokePreview(stroke)

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(!model.isStrokePreviewActive)
        #expect(model.rendererRecoveryError == nil)
        #expect(model.capabilities.canPaint)
        #expect(model.error?.code == .gpuExecution)
        #expect(try renderer.studioChecksum() == checksumBefore)
        #expect(
            renderer.debugSynchronousReplaySubmissionCount
                == synchronousReplayCountBefore
        )
    }

    @Test func finishFailureAfterCancellationCannotReplaceRecoveredState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let finish = ControlledPreviewSuspension()
        let model = StudioModel(
            project: project,
            renderer: renderer,
            strokePreviewOperation: StrokePreviewRendererOperation(
                update: { renderer, id, points, token in
                    try await renderer.appendStrokePreview(id: id, points: points, token: token)
                },
                finish: { renderer, stroke, token in
                    try await renderer.finishStrokePreview(stroke, token: token)
                    _ = try await finish.suspendOnce()
                }
            )
        )
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        let checksumBefore = try renderer.studioChecksum()

        #expect(model.beginStrokePreview(stroke) == .accepted)
        let commit = Task { @MainActor in
            await model.commitStrokePreview(stroke)
        }
        await finish.waitUntilSuspended()
        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()

        await finish.fail(message: "finish completed after cancellation")
        await commit.value

        #expect(model.project == project)
        #expect(model.error == nil)
        #expect(model.rendererRecoveryError == nil)
        #expect(model.capabilities.canPaint)
        #expect(try renderer.studioChecksum() == checksumBefore)
    }

    @Test func firstPreviewWorkAdmissionFailurePreservesPaintThroughModelCancellation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let painted = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 128,
            y: 128
        )
        project.commands = [.stroke(painted)]
        let previewSubmissions = CommandBufferLabelCounter(label: "Watercolor stroke preview")
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 9_000,
                maximumProjectThreads: 1_000_000
            ),
            debugCommandBufferError: { commandBuffer in
                previewSubmissions.record(commandBuffer.label)
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        let checksumBefore = try renderer.studioChecksum()
        var hostile = StrokeCommand.studioTestStroke(
            layerID: project.layers[0].id,
            x: 24,
            y: 128
        )
        hostile.points = (0..<9).map { index in
            StrokePoint(
                x: 24 + Double(index) * 208 / 8,
                y: 128,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            )
        }

        var initial = hostile
        initial.points = [hostile.points[0]]
        model.beginStrokePreview(initial)
        model.appendStrokePreview(id: hostile.id, points: Array(hostile.points[1...]))
        await model.waitForStrokePreviewIdle()
        await model.waitForStrokePreviewCancellation()

        #expect(!model.isStrokePreviewActive)
        #expect(model.error?.code == .workBudget)
        #expect(model.error?.recoverySuggestion.contains("smaller canvas") == true)
        #expect(previewSubmissions.count == 0)
        #expect(try renderer.studioChecksum() == checksumBefore)

        model.completeStroke(.studioTestStroke(
            layerID: project.layers[0].id,
            x: 128,
            y: 128
        ))
        #expect(model.project.commands.count == 2)
        #expect(model.error == nil)
    }

    @Test func canvasWetnessReflectsCompletedStrokesAndProjectReplay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        var waterStroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        waterStroke.tool = .water

        #expect(model.canvasWetness == 0)

        model.completeStroke(waterStroke)
        #expect(model.canvasWetness > 0.1)

        model.clearSelectedLayer()
        #expect(model.canvasWetness == 0)
    }

    @Test func selectingAnUnknownLayerDisablesNewPaintingButPreservesAnInFlightStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        model.selectedLayerID = UUID(uuidString: "187C458F-D40D-427D-970F-3E7A40FD301B")!
        model.completeStroke(stroke)

        #expect(!model.capabilities.canPaint)
        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdateCount == 1)
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 128, y: 128).alpha > 0.05)
    }

    @Test func completedStrokeTargetsThePointerDownLayerAfterSelectionChanges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let otherLayer = PaintLayer(
            id: UUID(uuidString: "0CD27F43-E900-467A-B7CB-D21A7B966681")!,
            name: "Other"
        )
        project.layers.append(otherLayer)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )

        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        model.selectedLayerID = otherLayer.id
        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(documentUpdateCount == 1)
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id).alpha > 0.05)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: otherLayer.id).alpha == 0)
    }

    @Test func completedStrokeFailureDoesNotPersistTheCommand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "deterministic GPU execution failure"]
        )
        var failedBuffer: MTLCommandBuffer?
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if failedBuffer == nil, commandBuffer.label == "Watercolor stroke" {
                    failedBuffer = commandBuffer
                }
                guard let failedBuffer, commandBuffer === failedBuffer else {
                    return commandBuffer.error
                }
                return injectedError
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let checksumBefore = try renderer.studioChecksum()
        let failedStroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "89204F9E-83C1-45F2-A9E7-4850732544AA")!,
            layerID: project.layers[0].id,
            x: 64,
            y: 64
        )

        model.completeStroke(failedStroke)

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(model.error?.code == .gpuExecution)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha == 0)

        let validStroke = StrokeCommand.studioTestStroke(
            id: UUID(uuidString: "664296E0-1872-47D9-9A08-E2FCFCB5DC80")!,
            layerID: project.layers[0].id,
            x: 192,
            y: 192
        )
        model.completeStroke(validStroke)

        #expect(model.project.commands == [.stroke(validStroke)])
        #expect(documentUpdates == [model.project])
        #expect(model.error == nil)
        #expect(try renderer.debugPixel(x: 64, y: 64).alpha == 0)
        #expect(try renderer.debugPixel(x: 192, y: 192).alpha > 0.1)
    }

    @Test func completedStrokeRollbackFailureDisablesPainting() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "stroke rollback failed"]
        )
        var shouldFail = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail,
                   commandBuffer.label == "Watercolor stroke"
                    || commandBuffer.label == "Watercolor replay" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        shouldFail = true

        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))

        #expect(model.project == project)
        #expect(model.rendererRecoveryError != nil)
        #expect(model.error == nil)
        #expect(!model.capabilities.canPaint)
    }

    @Test func configuringACanvasAttachesOnlyTheDisplayDelegate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let view = MTKView(frame: .zero)

        model.configureCanvas(view)

        #expect(view.device === device)
        #expect(view.colorPixelFormat == .bgra8Unorm)
        #expect(view.delegate != nil)
        #expect(view.delegate !== renderer)
        view.delegate?.mtkView(view, drawableSizeWillChange: CGSize(width: 320, height: 240))
        #expect(renderer.viewportSize == CGSize(width: 320, height: 240))
    }

    @Test func displayStateUpdatesInvalidateWithoutReattachingCanvasConfiguration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let view = InvalidatingMTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        model.configureCanvas(view)
        view.delegate = nil
        view.colorPixelFormat = .rgba8Unorm
        view.invalidationCount = 0

        model.zoom = 2
        model.pan = CGSize(width: 10, height: 20)
        model.updateCanvasDisplay(view)

        #expect(view.delegate == nil)
        #expect(view.colorPixelFormat == .rgba8Unorm)
        #expect(view.device === device)
        #expect(view.invalidationCount == 1)
    }

    @Test func renderFailurePreservesTheProjectAndReportsTheError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdateCount = 0
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { _ in documentUpdateCount += 1 }
        )
        let missingLayerID = UUID(uuidString: "DC0B6B55-5763-43B1-A8E9-73F5CCBBE79B")!

        model.completeStroke(.studioTestStroke(layerID: missingLayerID))

        #expect(model.project == project)
        #expect(documentUpdateCount == 0)
        #expect(model.error?.message.contains(missingLayerID.uuidString) == false)
        #expect(model.error?.message.contains("selected layer") == true)
        #expect(!model.capabilities.canUndo)
    }

    @Test func addingALayerSelectsItAndPublishesTheReplayedProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.addLayer()

        #expect(model.project.layers.map(\.name) == ["Layer 1", "Layer 2"])
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.rendererProject == model.project)
        #expect(renderer.project == project)
        #expect(documentUpdates == [model.project])
        #expect(model.error == nil)
        #expect(model.capabilities.canUndo)
    }

    @Test func duplicatingTheSelectedLayerSelectsTheCopy() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.layers[0].isVisible = false
        project.layers[0].opacity = 0.45
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.duplicateSelectedLayer()

        #expect(model.project.layers.count == 2)
        #expect(model.project.layers[1].name == "Layer 1 copy")
        #expect(model.project.layers[1].isVisible == false)
        #expect(model.project.layers[1].opacity == 0.45)
        #expect(model.project.layers[1].id != project.layers[0].id)
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func deletingTheSelectedLayerKeepsSelectionValid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        model.selectedLayerID = middle.id

        model.deleteSelectedLayer()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id, top.id])
        #expect(model.selectedLayerID == top.id)
        #expect(model.capabilities.canPaint)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func movingTheSelectedLayerUpChangesItsStackPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.moveSelectedLayerUp()

        #expect(model.project.layers.map(\.id) == [middle.id, project.layers[0].id, top.id])
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)
    }

    @Test func movingTheSelectedLayerDownChangesItsStackPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        project.layers.append(contentsOf: [middle, top])
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.selectedLayerID = top.id

        model.moveSelectedLayerDown()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id, top.id, middle.id])
        #expect(model.selectedLayerID == top.id)
        #expect(model.rendererProject == model.project)
    }

    @Test func renamingALayerPublishesATrimmedNonemptyName() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.renameLayer(id: project.layers[0].id, to: "  Sky wash  ")

        #expect(model.project.layers[0].name == "Sky wash")
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func changingLayerVisibilityPublishesTheReplayedCompositeMetadata() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.setLayerVisibility(id: project.layers[0].id, isVisible: false)

        #expect(model.project.layers[0].isVisible == false)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func metadataEditsReuseTheRendererAndCommitHistoryAndDocumentOnceEach() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let top = PaintLayer(name: "Top")
        project.layers.append(top)
        project.commands = [
            .stroke(.studioTestStroke(layerID: project.layers[0].id, x: 112, y: 128)),
            .stroke(.studioTestStroke(layerID: top.id, x: 144, y: 128))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let rendererIdentity = ObjectIdentifier(renderer)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.renameLayer(id: project.layers[0].id, to: "Ground")
        model.setLayerVisibility(id: project.layers[0].id, isVisible: false)
        model.moveSelectedLayerUp()
        model.previewLayerOpacity(id: top.id, opacity: 0.35)
        model.commitLayerOpacity(id: top.id)

        #expect(model.rendererIdentity == rendererIdentity)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates.count == 4)
        #expect(model.capabilities.canUndo)
        #expect(model.project.layers.first(where: { $0.id == top.id })?.opacity == 0.35)
    }

    @Test func changingLayerOpacityClampsItToTheRenderersSupportedRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.setLayerOpacity(id: project.layers[0].id, opacity: 1.5)
        #expect(model.project.layers[0].opacity == 1)
        #expect(model.rendererProject.layers[0].opacity == 1)

        model.setLayerOpacity(id: project.layers[0].id, opacity: -0.25)
        #expect(model.project.layers[0].opacity == 0)
        #expect(model.rendererProject.layers[0].opacity == 0)
    }

    @Test func opacityGesturePreviewsManyValuesAndCommitsOneProjectEdit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let layerID = project.layers[0].id

        model.previewLayerOpacity(id: layerID, opacity: 0.8)
        model.previewLayerOpacity(id: layerID, opacity: 0.5)
        model.previewLayerOpacity(id: layerID, opacity: 0.2)

        #expect(model.displayedLayerOpacity(id: layerID) == 0.2)
        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)

        model.commitLayerOpacity(id: layerID)

        #expect(model.displayedLayerOpacity(id: layerID) == 0.2)
        #expect(model.project.layers[0].opacity == 0.2)
        #expect(documentUpdates == [model.project])
        #expect(model.capabilities.canUndo)

        model.commitLayerOpacity(id: layerID)
        #expect(documentUpdates.count == 1)
    }

    @Test func failedOpacityCommitRestoresTheCommittedRendererPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.commands = [.stroke(.studioTestStroke(layerID: project.layers[0].id))]
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "persistent opacity commit failure"]
        )
        var shouldFail = false
        var failedMetadataCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Apply layer metadata" {
                    failedMetadataCount += 1
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let layerID = project.layers[0].id
        let committedChecksum = try renderer.studioChecksum()
        model.previewLayerOpacity(id: layerID, opacity: 0.1)
        #expect(try renderer.studioChecksum() != committedChecksum)
        shouldFail = true

        model.commitLayerOpacity(id: layerID)

        #expect(model.project == project)
        #expect(model.displayedLayerOpacity(id: layerID) == 1)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == committedChecksum)
        #expect(failedMetadataCount == 1)
        #expect(model.error?.code == .gpuExecution)
    }

    @Test func changingLayerOpacityIgnoresANonfiniteValue() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.setLayerOpacity(id: project.layers[0].id, opacity: .nan)

        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(documentUpdates.isEmpty)
    }

    @Test func mergingTheSelectedLayerDownSelectsTheDestinationLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let top = PaintLayer(name: "Top")
        project.layers.append(top)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        model.selectedLayerID = top.id

        model.mergeSelectedLayerDown()

        #expect(model.project.layers.map(\.id) == [project.layers[0].id])
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.project.commands.count == 1)
        if case let .mergeDown(command) = model.project.commands[0] {
            #expect(command.sourceLayerID == top.id)
            #expect(command.destinationLayerID == project.layers[0].id)
        } else {
            Issue.record("Expected a merge-down command")
        }
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func clearingTheSelectedLayerRecordsAndReplaysTheCommand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.clearSelectedLayer()

        #expect(model.project.commands.count == 1)
        if case let .clearLayer(command) = model.project.commands[0] {
            #expect(command.layerID == project.layers[0].id)
        } else {
            Issue.record("Expected a clear-layer command")
        }
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func selectingPaperPublishesAndReplaysTheProject() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(.rough)
        await model.waitForStructuralChanges()

        #expect(model.project.paper == .rough)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == model.project)
        #expect(documentUpdates == [model.project])
    }

    @Test func changingPaperReplaysPaintedRasterExactlyAsTheSavedProjectReopens() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        let stroke = StrokeCommand.studioTestStroke(layerID: project.layers[0].id)
        project.commands = [.stroke(stroke)]
        let originalRenderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: originalRenderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(.rough)
        await model.waitForStructuralChanges()

        let reopenedProject = try PaintingDocumentCodec.decode(
            PaintingDocumentCodec.encode(model.project)
        )
        let reopenedRenderer = try WatercolorRenderer(project: reopenedProject, device: device)
        let liveRenderer = model.rendererForTesting
        #expect(model.project == reopenedProject)
        #expect(liveRenderer.project == reopenedProject)
        #expect(
            try liveRenderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
                == reopenedRenderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
        )
        #expect(
            try liveRenderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
                == reopenedRenderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
        )
        #expect(try liveRenderer.studioChecksum() == reopenedRenderer.studioChecksum())
        #expect(model.canvasWetness == reopenedRenderer.canvasWetness)
        #expect(model.rendererIdentity != ObjectIdentifier(originalRenderer))
        #expect(liveRenderer.debugResources.pipelines == originalRenderer.debugResources.pipelines)
        #expect(documentUpdates == [model.project])
    }

    @Test func selectingTheCurrentPaperDoesNotPublishANoOpEdit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.selectPaper(project.paper)

        #expect(model.project == project)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
    }

    @Test func failedPaperReplayPreservesTheLiveModelRendererAndDocument() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.studioTestProject()
        project.commands = [
            .stroke(.studioTestStroke(layerID: project.layers[0].id))
        ]
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "deterministic paper replay failure"]
        )
        var shouldFail = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Watercolor replay" {
                    failedReplayCount += 1
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let rendererIdentity = model.rendererIdentity
        let checksum = try renderer.studioChecksum()
        let pigment = try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id)
        let wetness = try renderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id)
        let canvasWetness = model.canvasWetness
        shouldFail = true

        model.selectPaper(.rough)
        await model.waitForStructuralChanges()

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(model.rendererIdentity == rendererIdentity)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(try renderer.studioChecksum() == checksum)
        #expect(try renderer.debugPixel(x: 128, y: 128, layerID: project.layers[0].id) == pigment)
        #expect(try renderer.debugWetness(x: 128, y: 128, layerID: project.layers[0].id) == wetness)
        #expect(model.canvasWetness == canvasWetness)
        #expect(model.error?.code == .gpuExecution)
        #expect(failedReplayCount == 1)
        // The failed change leaves the picker on the paper that is actually
        // in use, never stuck showing a choice that did not apply.
        #expect(model.displayedPaper == project.paper)
    }

    @Test func brushSizeAdjustmentsStayWithinThePaintableRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.adjustBrushSize(by: -100)
        #expect(model.brush.size == 1)

        model.adjustBrushSize(by: 1_000)
        #expect(model.brush.size == 300)
    }

    @Test func selectingAStyleAppliesItsWatercolorParameters() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.brush.color = PaintColor(red: 0.1, green: 0.2, blue: 0.3)
        model.brush.shape = .fan

        model.selectStyle(.wetOnWet)

        #expect(model.brush.style == .wetOnWet)
        #expect(model.brush.opacity == 0.3)
        #expect(model.brush.flow == 0.5)
        #expect(model.brush.water == 0.9)
        #expect(model.brush.edgeBloom == 0.8)
        #expect(model.brush.shape == .fan)
        #expect(model.brush.color == PaintColor(red: 0.1, green: 0.2, blue: 0.3))
    }

    @Test func toolShortcutsSelectEveryPaintingTool() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let cases: [(String, PaintTool)] = [
            ("B", .brush),
            ("e", .eraser),
            ("W", .water),
            ("s", .smudge),
            ("M", .smear),
            ("d", .dry)
        ]

        for (shortcut, expectedTool) in cases {
            #expect(model.selectTool(forShortcut: shortcut))
            #expect(model.selectedTool == expectedTool)
        }

        #expect(!model.selectTool(forShortcut: "x"))
        #expect(model.selectedTool == .dry)
    }

    @Test func fittingTheCanvasRestoresTheAspectFitViewport() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.zoom = 4.25
        model.pan = CGSize(width: 120, height: -45)

        model.fitCanvas()

        #expect(model.zoom == 1)
        #expect(model.pan == .zero)
    }

    @Test func unavailableFocusedCommandsAreSilentNoOps() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.undo()
        model.redo()
        model.selectedLayerID = UUID()
        model.drySelectedLayer()
        #expect(model.project == project)
    }

    @Test func layerActionAvailabilityReflectsSelectionAndLayerLimits() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        #expect(model.canAddLayer)
        #expect(model.canDuplicateSelectedLayer)
        #expect(!model.canDeleteSelectedLayer)
        #expect(!model.canMoveSelectedLayerUp)
        #expect(!model.canMoveSelectedLayerDown)
        #expect(!model.canMergeSelectedLayerDown)

        model.selectedLayerID = UUID()
        #expect(!model.canDuplicateSelectedLayer)
    }

    @Test func previewOwnershipDisablesHistoryAndEveryLayerAction() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.completeStroke(.studioTestStroke(layerID: project.layers[0].id))
        model.addLayer()
        model.addLayer()
        model.addLayer()
        model.undo()
        model.selectedLayerID = model.project.layers[1].id

        #expect(model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)
        #expect(model.canAddLayer)
        #expect(model.canDuplicateSelectedLayer)
        #expect(model.canDeleteSelectedLayer)
        #expect(model.canMoveSelectedLayerUp)
        #expect(model.canMoveSelectedLayerDown)
        #expect(model.canMergeSelectedLayerDown)

        let preview = StrokeCommand.studioTestStroke(layerID: model.selectedLayerID)
        #expect(model.beginStrokePreview(preview) == .accepted)

        #expect(!model.canModifyProject)
        #expect(!model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(!model.canAddLayer)
        #expect(!model.canDuplicateSelectedLayer)
        #expect(!model.canDeleteSelectedLayer)
        #expect(!model.canMoveSelectedLayerUp)
        #expect(!model.canMoveSelectedLayerDown)
        #expect(!model.canMergeSelectedLayerDown)

        model.cancelStrokePreview()
        await model.waitForStrokePreviewCancellation()

        #expect(model.canModifyProject)
        #expect(model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)
    }

    @Test func duplicationRemainsAvailableAfterManyHistoricalDuplicateDeleteCycles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = PaintLayer(name: "Generation 0")
        var editor = ProjectEditor(project: PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [firstLayer],
            commands: [.stroke(.studioTestStroke(layerID: firstLayer.id))]
        ))
        for generation in 1...16 {
            let sourceID = try #require(editor.project.layers.first?.id)
            try editor.duplicateLayer(id: sourceID, named: "Generation \(generation)")
            try editor.removeLayer(id: sourceID)
        }
        let renderer = try WatercolorRenderer(project: editor.project, device: device)
        let model = StudioModel(project: editor.project, renderer: renderer)

        #expect(model.canDuplicateSelectedLayer)
        model.duplicateSelectedLayer()

        #expect(model.project.layers.count == 2)
        #expect(model.selectedLayerID == model.project.layers[1].id)
        #expect(model.error == nil)
    }

    @Test func dismissingTheAlertClearsTheIdentifiableFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        model.completeStroke(.studioTestStroke(layerID: UUID()))
        #expect(model.error != nil)

        model.dismissError()

        #expect(model.error == nil)
    }

    @Test func failedStructuralReplayPreservesModelRendererSelectionAndDocument() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let injectedError = NSError(
            domain: "StudioModelTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "deterministic structural replay failure"]
        )
        var shouldFail = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFail, commandBuffer.label == "Watercolor replay" {
                    failedReplayCount += 1
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        shouldFail = true

        model.addLayer()

        #expect(model.project == project)
        #expect(renderer.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(documentUpdates.isEmpty)
        #expect(!model.capabilities.canUndo)
        #expect(model.error?.code == .gpuExecution)
        #expect(failedReplayCount == 1)
    }

    @Test func structuralUndoAndRedoRestoreBoundedRendererCheckpointsWithoutReplay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        var replayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" { replayCount += 1 }
                return commandBuffer.error
            }
        )
        let model = StudioModel(project: project, renderer: renderer)
        let originalIdentity = model.rendererIdentity
        let originalChecksum = try renderer.studioChecksum()

        model.addLayer()
        let addedProject = model.project
        let addedIdentity = model.rendererIdentity
        let replayCountAfterEdit = replayCount

        model.undo()
        #expect(model.project == project)
        #expect(model.rendererIdentity == originalIdentity)
        #expect(try model.rendererForTesting.studioChecksum() == originalChecksum)
        #expect(replayCount == replayCountAfterEdit)

        model.redo()
        #expect(model.project == addedProject)
        #expect(model.rendererIdentity == addedIdentity)
        #expect(replayCount == replayCountAfterEdit)
        #expect(model.rendererCheckpointCountForTesting <= 2)
    }

    @Test func rendererCheckpointCacheIsDeduplicatedAndBounded() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.addLayer()
        model.addLayer()
        model.addLayer()
        #expect(model.rendererCheckpointCountForTesting == 2)

        model.undo()
        model.redo()
        model.undo()
        #expect(model.rendererCheckpointCountForTesting <= 2)
    }

    @Test func checkpointBudgetEvictsOldSnapshotsBeforeAllocatingCandidate() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        var checkpointCountsDuringCandidateReplay: [Int] = []
        weak var observedModel: StudioModel?
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay", let observedModel {
                    checkpointCountsDuringCandidateReplay.append(
                        observedModel.rendererCheckpointCountForTesting
                    )
                }
                return commandBuffer.error
            }
        )
        let oneCheckpointBudget = renderer.estimatedResourceBytes + 1_024
        let model = StudioModel(
            project: project,
            renderer: renderer,
            rendererCheckpointByteBudget: oneCheckpointBudget
        )
        observedModel = model

        model.selectPaper(.rough)
        await model.waitForStructuralChanges()
        let roughRendererIdentity = model.rendererIdentity
        model.selectPaper(.hotPress)
        await model.waitForStructuralChanges()

        #expect(model.rendererCheckpointCountForTesting == 1)
        #expect(model.rendererCheckpointBytesForTesting <= oneCheckpointBudget)
        // Each asynchronous paper change replays twice: once to initialize
        // the blank candidate and once to replay the history through it.
        #expect(checkpointCountsDuringCandidateReplay == [0, 0, 0, 0])
        model.undo()
        #expect(model.project.paper == .rough)
        #expect(model.rendererIdentity == roughRendererIdentity)
    }

    @Test func devicePeakAdmissionEvictsRetainedCheckpointsBeforeCandidateAllocation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugResourcePolicy: RendererResourcePolicy(
                maximumWorkingSetBytes: 5_505_416
            )
        )
        let model = StudioModel(
            project: project,
            renderer: renderer,
            rendererCheckpointByteBudget: 64 * 1024 * 1024
        )

        model.selectPaper(.rough)
        await model.waitForStructuralChanges()
        #expect(model.project.paper == .rough)
        #expect(model.rendererCheckpointCountForTesting == 1)

        model.selectPaper(.hotPress)
        await model.waitForStructuralChanges()

        #expect(model.project.paper == .hotPress)
        #expect(model.rendererCheckpointCountForTesting == 1)
        #expect(model.error == nil)
    }

    @Test func oversizedRendererIsNeverRetainedAndUndoFallsBackToEquivalentReplay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let originalChecksum = try renderer.studioChecksum()
        let model = StudioModel(
            project: project,
            renderer: renderer,
            rendererCheckpointByteBudget: renderer.estimatedResourceBytes - 1
        )

        model.addLayer()
        #expect(model.rendererCheckpointCountForTesting == 0)
        #expect(model.rendererCheckpointBytesForTesting == 0)
        model.undo()

        #expect(model.project == project)
        #expect(model.rendererIdentity != ObjectIdentifier(renderer))
        #expect(try model.rendererForTesting.studioChecksum() == originalChecksum)
    }

    @Test func directLayerReorderingMovesTheDraggedLayerAndKeepsItSelected() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layers = [PaintLayer(name: "Bottom"), PaintLayer(name: "Middle"), PaintLayer(name: "Top")]
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: layers
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        model.moveLayer(id: layers[2].id, toLayerID: layers[0].id)

        #expect(model.project.layers.map(\.id) == [layers[2].id, layers[0].id, layers[1].id])
        #expect(model.selectedLayerID == layers[2].id)
        #expect(model.capabilities.canUndo)
    }

    @Test func pickerColorsPopulateAMostRecentDeduplicatedBoundedList() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioTestProject()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)
        let colors = (0..<7).map { index in
            PaintColor.fromSRGB(red: Double(index) / 8, green: 0.25, blue: 0.5)
        }

        colors.forEach(model.selectPickerColor)
        model.selectPickerColor(colors[3])

        #expect(model.recentColors.count == 6)
        #expect(model.recentColors.first == colors[3])
        #expect(model.recentColors.filter { $0 == colors[3] }.count == 1)
        #expect(model.brush.color == colors[3])
    }
}

private final class CommandBufferLabelCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var storage = 0

    init(label: String) {
        self.label = label
    }

    func record(_ candidate: String?) {
        guard candidate == label else { return }
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor ControlledPreviewSuspension {
    private enum Outcome {
        case resume
        case failure(String)
    }

    private var hasSuspended = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Outcome, Never>?
    private var pendingOutcome: Outcome?

    func suspendOnce() async throws -> Bool {
        guard !hasSuspended else { return false }
        hasSuspended = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        let outcome = if let pendingOutcome {
            pendingOutcome
        } else {
            await withCheckedContinuation { continuation in
                completion = continuation
            }
        }
        if case let .failure(message) = outcome {
            throw ControlledPreviewError(message: message)
        }
        return true
    }

    func waitUntilSuspended() async {
        guard !hasSuspended else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resolve(with: .resume)
    }

    func fail(message: String) {
        resolve(with: .failure(message))
    }

    private func resolve(with outcome: Outcome) {
        if let completion {
            self.completion = nil
            completion.resume(returning: outcome)
        } else {
            pendingOutcome = outcome
        }
    }
}

private actor ControlledPreviewSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct ControlledPreviewError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class InvalidatingMTKView: MTKView {
    var invalidationCount = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidationCount += 1
        super.setNeedsDisplay(invalidRect)
    }
}

private extension PaintingProject {
    static func studioTestProject() -> Self {
        Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "F63BBA2D-81C1-4ABF-B0D4-99B3F8D63B8C")!,
                    name: "Layer 1"
                )
            ]
        )
    }

    static func studioPointCapacityProject(pointCount: Int) -> Self {
        var project = studioTestProject()
        let fullStrokeCount = pointCount / Self.maximumStrokePointCount
        let remainderPointCount = pointCount % Self.maximumStrokePointCount
        let points = Array(
            repeating: StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0),
            count: Self.maximumStrokePointCount
        )
        let historicalLayerID = UUID()
        project.commands = (0..<fullStrokeCount).map { _ in
            .stroke(StrokeCommand(
                layerID: historicalLayerID,
                tool: .brush,
                brush: .default,
                points: points
            ))
        }
        if remainderPointCount > 0 {
            project.commands.append(.stroke(StrokeCommand(
                layerID: historicalLayerID,
                tool: .brush,
                brush: .default,
                points: Array(repeating: points[0], count: remainderPointCount)
            )))
        }
        return project
    }
}

private extension StrokeCommand {
    static func studioTestStroke(
        id: UUID = UUID(),
        layerID: UUID,
        x: Double = 128,
        y: Double = 128
    ) -> Self {
        Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}

private extension WatercolorRenderer {
    func studioChecksum() throws -> UInt64 {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The test could not access image bytes")
        }
        return (0..<CFDataGetLength(data)).reduce(UInt64(0)) { checksum, index in
            (checksum &* 16_777_619) ^ UInt64(bytes[index])
        }
    }
}
