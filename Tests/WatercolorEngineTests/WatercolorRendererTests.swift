import CoreGraphics
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine

@Suite @MainActor struct WatercolorRendererTests {
    @Test func redAndBlueWetStrokesMix() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testLine(
            layerID: project.layers[0].id,
            color: PaintColor(red: 1, green: 0, blue: 0),
            y: 32,
            water: 0.9
        ))
        try renderer.render(stroke: .testLine(
            layerID: project.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            y: 32,
            water: 0.9
        ))

        let pixel = try renderer.debugPixel(x: 32, y: 32)
        #expect(pixel.red > 0.1)
        #expect(pixel.blue > 0.1)
    }

    @Test func transparentPigmentDoesNotTintLaterMixing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        try renderer.render(stroke: .testDot(
            layerID: layerID,
            color: PaintColor(red: 1, green: 0, blue: 0, alpha: 0)
        ))
        try renderer.render(stroke: .testDot(
            layerID: layerID,
            color: PaintColor(red: 0, green: 0, blue: 1, alpha: 1)
        ))

        let mixed = try renderer.debugPixel(x: 32, y: 32)
        #expect(mixed.red < 0.01)
        #expect(mixed.blue > 0.1)
    }

    @Test func eraserLowersConcentration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: .brush, pressure: 1))
        let before = try renderer.debugPixel(x: 32, y: 32).alpha
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: .eraser, pressure: 1))

        #expect(try renderer.debugPixel(x: 32, y: 32).alpha < before)
    }

    @Test func rendererSizesReusableTextureArraysToActualLayerNeeds() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = renderer.debugResources

        try renderer.render(stroke: .testDot(layerID: project.layers[0].id))
        let after = renderer.debugResources

        #expect(before == after)
        #expect(before.pigmentArrayLength == 1)
        #expect(before.wetnessArrayLength == 1)
        #expect(before.pigmentPixelFormat == .rgba16Float)
        #expect(before.wetnessPixelFormat == .r16Float)
        #expect(before.compositePixelFormat == .bgra8Unorm)
    }

    @Test func bulkLayerFieldReadbackPreservesTwoSliceLayoutBoundsAndPositiveFields() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bottom = PaintLayer(
            id: UUID(uuidString: "6042E515-0F0C-429C-ACB8-2757B445C0E4")!,
            name: "Bottom"
        )
        let top = PaintLayer(
            id: UUID(uuidString: "A391560D-C044-4564-968E-BAC8A469DD4C")!,
            name: "Top"
        )
        let project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        var bottomStroke = StrokeCommand.testDot(
            layerID: bottom.id,
            color: PaintColor(red: 1, green: 0, blue: 0),
            x: 16,
            y: 8
        )
        bottomStroke.brush.water = 0.25
        var topStroke = StrokeCommand.testDot(
            layerID: top.id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            x: 48,
            y: 56
        )
        topStroke.brush.water = 0.9
        try renderer.renderAndWait(stroke: bottomStroke)
        try renderer.renderAndWait(stroke: topStroke)

        let bottomFields = try renderer.debugLayerFields(layerID: bottom.id)
        let topFields = try renderer.debugLayerFields(layerID: top.id)

        for fields in [bottomFields, topFields] {
            #expect(fields.width == 64)
            #expect(fields.height == 64)
            #expect(fields.pigment.count == 4_096)
            #expect(fields.wetness.count == 4_096)
        }
        let bottomPigment = try bottomFields.pigmentColor(x: 16, y: 8)
        let bottomWetness = try bottomFields.wetnessValue(x: 16, y: 8)
        #expect(bottomPigment.alpha > 0)
        #expect(bottomPigment.red > bottomPigment.blue)
        #expect(bottomWetness > 0)
        #expect(try bottomFields.pigmentColor(x: 48, y: 56).alpha == 0)
        #expect(try bottomFields.wetnessValue(x: 48, y: 56) == 0)

        let topPigment = try topFields.pigmentColor(x: 48, y: 56)
        let topWetness = try topFields.wetnessValue(x: 48, y: 56)
        #expect(topPigment.alpha > 0)
        #expect(topPigment.blue > topPigment.red)
        #expect(topWetness > bottomWetness)
        #expect(try topFields.pigmentColor(x: 16, y: 8).alpha == 0)
        #expect(try topFields.wetnessValue(x: 16, y: 8) == 0)

        #expect(
            try bottomFields.pigmentColor(x: 16, y: 8)
                == renderer.debugPixel(x: 16, y: 8, layerID: bottom.id)
        )
        #expect(
            try bottomFields.wetnessValue(x: 16, y: 8)
                == renderer.debugWetness(x: 16, y: 8, layerID: bottom.id)
        )
        #expect(
            try topFields.pigmentColor(x: 48, y: 56)
                == renderer.debugPixel(x: 48, y: 56, layerID: top.id)
        )
        #expect(
            try topFields.wetnessValue(x: 48, y: 56)
                == renderer.debugWetness(x: 48, y: 56, layerID: top.id)
        )
        #expect(throws: RendererError.self) {
            try bottomFields.pigmentColor(x: -1, y: 0)
        }
        #expect(throws: RendererError.self) {
            try topFields.wetnessValue(x: 64, y: 0)
        }
        let missingLayerID = UUID(uuidString: "8CE99563-FF17-4FF7-9A52-9243478037E6")!
        #expect(throws: RendererError.unknownLayer(missingLayerID)) {
            try renderer.debugLayerFields(layerID: missingLayerID)
        }
    }

    @Test func pointerDownUsesInitializedPreviewSnapshotTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = renderer.debugResources

        let token = try renderer.beginStrokePreview(.testDot(layerID: project.layers[0].id))
        let afterPointerDown = renderer.debugResources

        #expect(afterPointerDown.previewTextures == before.previewTextures)
        #expect(afterPointerDown.previewTextureAllocationCount == before.previewTextureAllocationCount)
        #expect(afterPointerDown.previewTextureAllocationCount == 2)
        #expect(afterPointerDown.previewArrayLength == 1)
        try renderer.cancelStrokePreview(token)
    }

    @Test func repeatedStrokesReuseSingleLayerPreviewTextures() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layers = [PaintLayer(name: "First"), PaintLayer(name: "Second")]
        let project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: layers
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = renderer.debugResources

        for index in 0..<20 {
            let layer = layers[index % layers.count]
            let stroke = StrokeCommand.testDot(
                layerID: layer.id,
                x: Double(20 + index),
                y: 32
            )
            let token = try renderer.beginStrokePreview(stroke)
            #expect(renderer.debugResources.previewTextures == before.previewTextures)
            try await renderer.finishStrokePreview(stroke, token: token)
        }

        #expect(renderer.debugResources.previewTextures == before.previewTextures)
        #expect(renderer.debugResources.previewTextureAllocationCount == 2)
        #expect(renderer.debugResources.previewArrayLength == 1)
    }

    @Test func stalePublicPreviewTokensCannotAdoptReusedStrokeIDTransaction() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let strokeID = UUID()
        let first = StrokeCommand.testDot(
            id: strokeID,
            layerID: project.layers[0].id,
            x: 16,
            y: 16
        )
        let second = StrokeCommand.testDot(
            id: strokeID,
            layerID: project.layers[0].id,
            x: 48,
            y: 48
        )

        let firstToken = try renderer.beginStrokePreview(first)
        let delayedCall = RendererPreviewCallSuspension()
        let staleCalls = Task { @MainActor in
            await delayedCall.suspend()
            var rejectedCalls: [Bool] = []
            do {
                try await renderer.appendStrokePreview(
                    id: first.id,
                    points: [],
                    token: firstToken
                )
                rejectedCalls.append(false)
            } catch {
                rejectedCalls.append(error as? RendererError == .invalidStrokePreview)
            }
            do {
                try await renderer.finishStrokePreview(first, token: firstToken)
                rejectedCalls.append(false)
            } catch {
                rejectedCalls.append(error as? RendererError == .invalidStrokePreview)
            }
            do {
                try renderer.cancelStrokePreview(firstToken)
                rejectedCalls.append(false)
            } catch {
                rejectedCalls.append(error as? RendererError == .invalidStrokePreview)
            }
            return rejectedCalls
        }
        await delayedCall.waitUntilSuspended()

        try renderer.cancelStrokePreview(firstToken)
        let secondToken = try renderer.beginStrokePreview(second)
        await delayedCall.resume()

        #expect(await staleCalls.value == [true, true, true])

        try await renderer.finishStrokePreview(second, token: secondToken)
        #expect(try renderer.debugPixel(x: 48, y: 48).alpha > 0.1)
    }

    @Test func actualGPUFinishCancelOverlapLeavesTheLaterTransactionUsable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let finishWaitEvent = try #require(device.makeSharedEvent())
        let finishWaitValue: UInt64 = 1
        let finishCommitted = RendererPreviewCommandBufferMilestone()
        let cancellationBegan = RendererPreviewMilestone()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugPreviewFinishWaitEvent: finishWaitEvent,
            value: finishWaitValue,
            finishDidCommit: { commandBuffer in
                finishCommitted.record(commandBuffer)
            },
            cancellationDidBegin: {
                cancellationBegan.record()
            }
        )
        let checksumBefore = try renderer.compositeChecksum()
        let first = StrokeCommand.testDot(
            id: UUID(uuidString: "A20E398B-E36C-46CB-868E-54A0BD84AD65")!,
            layerID: project.layers[0].id,
            x: 16,
            y: 16
        )
        let firstToken = try renderer.beginStrokePreview(first)
        let finishing = Task { @MainActor in
            try await renderer.finishStrokePreview(first, token: firstToken)
        }
        let finishCommandBuffer = await finishCommitted.waitForCommandBuffer().commandBuffer
        #expect(finishWaitEvent.signaledValue < finishWaitValue)
        #expect(
            finishCommandBuffer.status == .committed
                || finishCommandBuffer.status == .scheduled
        )

        let cancelling = Task { @MainActor in
            try await renderer.restoreStrokePreviewCancellation(firstToken)
        }
        await cancellationBegan.waitUntilRecorded()
        #expect(finishWaitEvent.signaledValue < finishWaitValue)
        #expect(
            finishCommandBuffer.status == .committed
                || finishCommandBuffer.status == .scheduled
        )
        #expect(throws: RendererError.invalidStrokePreview) {
            _ = try renderer.beginStrokePreview(
                StrokeCommand.testDot(layerID: project.layers[0].id, x: 32, y: 32)
            )
        }

        finishWaitEvent.signaledValue = finishWaitValue

        await #expect(throws: RendererError.invalidStrokePreview) {
            try await finishing.value
        }
        try await cancelling.value
        #expect(try renderer.compositeChecksum() == checksumBefore)
        let later = StrokeCommand.testDot(
            id: UUID(uuidString: "05228DF2-F510-44E2-881F-896B2DD1E6D5")!,
            layerID: project.layers[0].id,
            x: 48,
            y: 48
        )
        let laterToken = try renderer.beginStrokePreview(later)
        try await renderer.finishStrokePreview(later, token: laterToken)

        var replayProject = project
        replayProject.commands = [.stroke(later)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func synchronousCancelCannotDisplaceAsyncCancellationBeforeReplaySubmission() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let wet = PaintLayer(name: "Wet")
        let selected = PaintLayer(name: "Selected")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [wet, selected]
        )
        project.commands = [.stroke(.testDot(layerID: wet.id, x: 16, y: 16))]
        let cancellationSubmission = RendererPreviewCallSuspension()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugPreviewCancellationWillSubmit: {
                await cancellationSubmission.suspend()
            }
        )
        var discarded = StrokeCommand.testDot(layerID: selected.id)
        discarded.points = (0..<9).map { index in
            StrokePoint(
                x: Double(24 + index * 3),
                y: 40,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = discarded
        initial.points = [discarded.points[0]]
        let discardedToken = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: discarded.id,
            points: Array(discarded.points.dropFirst()),
            token: discardedToken
        )

        let authoritativeCancellation = Task { @MainActor in
            try await renderer.restoreStrokePreviewCancellation(discardedToken)
        }
        await cancellationSubmission.waitUntilSuspended()

        #expect(throws: RendererError.invalidStrokePreview) {
            try renderer.cancelStrokePreview(discardedToken)
        }
        let later = StrokeCommand.testDot(layerID: selected.id, x: 48, y: 48)
        #expect(throws: RendererError.invalidStrokePreview) {
            _ = try renderer.beginStrokePreview(later)
        }

        await cancellationSubmission.resume()
        try await authoritativeCancellation.value
        let laterToken = try renderer.beginStrokePreview(later)
        try await renderer.finishStrokePreview(later, token: laterToken)

        var replayProject = project
        replayProject.commands.append(.stroke(later))
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func failedSynchronousCancellationRetainsOwnershipUntilRestorationRetry() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 75,
            userInfo: [NSLocalizedDescriptionKey: "cancellation restore failed"]
        )
        var shouldFailCancellation = true
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
        let checksumBefore = try renderer.compositeChecksum()
        var discarded = StrokeCommand.testDot(layerID: project.layers[0].id)
        discarded.points = (0..<9).map { index in
            StrokePoint(
                x: Double(16 + index * 4),
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = discarded
        initial.points = [discarded.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: discarded.id,
            points: Array(discarded.points.dropFirst()),
            token: token
        )

        #expect(throws: RendererError.self) {
            try renderer.cancelStrokePreview(token)
        }
        do {
            _ = try renderer.beginStrokePreview(
                .testDot(layerID: project.layers[0].id, x: 48, y: 48)
            )
            Issue.record("Failed cancellation admitted a later preview")
            return
        } catch let error as RendererError {
            #expect(error == .invalidStrokePreview)
        }
        #expect(throws: RendererError.invalidStrokePreview) {
            try renderer.render(stroke: .testDot(layerID: project.layers[0].id))
        }
        #expect(throws: RendererError.invalidStrokePreview) {
            try renderer.replay(project: project)
        }

        shouldFailCancellation = false
        try await renderer.restoreStrokePreviewCancellation(token)
        #expect(try renderer.compositeChecksum() == checksumBefore)

        let later = StrokeCommand.testDot(layerID: project.layers[0].id, x: 48, y: 48)
        let laterToken = try renderer.beginStrokePreview(later)
        try await renderer.finishStrokePreview(later, token: laterToken)
        var replayProject = project
        replayProject.commands.append(.stroke(later))
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func activePreviewRejectsEveryPublicNontransactionalMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let preview = StrokeCommand.testDot(layerID: project.layers[0].id)
        let otherStroke = StrokeCommand.testDot(
            layerID: project.layers[0].id,
            x: 16,
            y: 16
        )

        func assertRejected(
            _ label: String,
            prepare: (WatercolorRenderer) throws -> Void = { _ in },
            operation: (WatercolorRenderer) throws -> Void
        ) throws {
            let renderer = try WatercolorRenderer(project: project, device: device)
            try prepare(renderer)
            let checksumBefore = try renderer.compositeChecksum()
            let projectBefore = renderer.project
            let token = try renderer.beginStrokePreview(preview)
            do {
                try operation(renderer)
                Issue.record("Expected active preview to reject \(label)")
            } catch let error as RendererError {
                #expect(error == .invalidStrokePreview)
            }
            try renderer.cancelStrokePreview(token)
            #expect(renderer.project == projectBefore)
            #expect(try renderer.compositeChecksum() == checksumBefore)
        }

        try assertRejected("render") { renderer in
            try renderer.render(stroke: otherStroke)
        }
        try assertRejected("renderAndWait") { renderer in
            try renderer.renderAndWait(stroke: otherStroke)
        }
        try assertRejected("recordRenderedStroke") { renderer in
            try renderer.recordRenderedStroke(otherStroke)
        }
        try assertRejected("replay") { renderer in
            try renderer.replay(project: project)
        }
        try assertRejected("applyMetadata") { renderer in
            var updated = project
            updated.layers[0].opacity = 0.5
            try renderer.applyMetadata(project: updated)
        }
        try assertRejected("dry") { renderer in
            try renderer.dry(layerID: project.layers[0].id, steps: 1)
        }
        try assertRejected("previewLayerOpacity") { renderer in
            try renderer.previewLayerOpacity(id: project.layers[0].id, opacity: 0.5)
        }
        try assertRejected(
            "clearLayerOpacityPreview",
            prepare: { renderer in
                try renderer.previewLayerOpacity(id: project.layers[0].id, opacity: 0.5)
            },
            operation: { renderer in
                try renderer.clearLayerOpacityPreview(id: project.layers[0].id)
            }
        )
    }

    @Test func atomicRenderAndRecordRejectsEveryProspectiveProjectBoundary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        func assertRejected(
            project: PaintingProject,
            limits: ProjectAdmissionLimits,
            stroke: StrokeCommand,
            expected: ProjectValidationError
        ) throws {
            var strokeSubmissions = 0
            let renderer = try WatercolorRenderer(
                project: project,
                device: device,
                debugProjectAdmissionLimits: limits,
                debugCommandBufferError: { commandBuffer in
                    if commandBuffer.label == "Watercolor stroke" {
                        strokeSubmissions += 1
                    }
                    return commandBuffer.error
                }
            )
            let checksumBefore = try renderer.compositeChecksum()

            #expect(throws: RendererError.invalidProject(expected)) {
                try renderer.renderAndRecord(stroke: stroke)
            }

            #expect(strokeSubmissions == 0)
            #expect(renderer.project == project)
            #expect(try renderer.compositeChecksum() == checksumBefore)
        }

        var commandProject = PaintingProject.testCanvas(64)
        commandProject.commands = (0..<2).map { _ in
            .clearLayer(LayerCommand(layerID: UUID()))
        }
        let commandStroke = StrokeCommand.testDot(layerID: commandProject.layers[0].id)
        try assertRejected(
            project: commandProject,
            limits: ProjectAdmissionLimits(
                maximumCommandCount: 2,
                maximumTotalStrokePointCount: 8,
                maximumSerializedStorageBytes: 32 * 1024
            ),
            stroke: commandStroke,
            expected: .commandLimitExceeded(3)
        )

        var pointProject = PaintingProject.testCanvas(64)
        var existingStroke = StrokeCommand.testDot(layerID: pointProject.layers[0].id)
        existingStroke.points.append(StrokePoint(
            x: 33, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 1
        ))
        pointProject.commands = [.stroke(existingStroke)]
        var pointStroke = StrokeCommand.testDot(layerID: pointProject.layers[0].id)
        pointStroke.points.append(StrokePoint(
            x: 17, y: 16, pressure: 1, tiltX: 0, tiltY: 0, time: 1
        ))
        try assertRejected(
            project: pointProject,
            limits: ProjectAdmissionLimits(
                maximumCommandCount: 4,
                maximumTotalStrokePointCount: 3,
                maximumSerializedStorageBytes: 32 * 1024
            ),
            stroke: pointStroke,
            expected: .totalStrokePointLimitExceeded(4)
        )

        let storageProject = PaintingProject.testCanvas(64)
        let storageStroke = StrokeCommand.testDot(layerID: storageProject.layers[0].id)
        try assertRejected(
            project: storageProject,
            limits: ProjectAdmissionLimits(
                maximumCommandCount: 4,
                maximumTotalStrokePointCount: 8,
                maximumSerializedStorageBytes: 6_000
            ),
            stroke: storageStroke,
            expected: .documentByteLimitExceeded(7_454)
        )

        let duplicateID = UUID(uuidString: "4C8D7524-9274-453E-B2F9-CDA1B196AB87")!
        var duplicateProject = PaintingProject.testCanvas(64)
        duplicateProject.commands = [
            .clearLayer(LayerCommand(id: duplicateID, layerID: UUID()))
        ]
        let duplicateStroke = StrokeCommand.testDot(
            id: duplicateID,
            layerID: duplicateProject.layers[0].id
        )
        try assertRejected(
            project: duplicateProject,
            limits: ProjectAdmissionLimits(
                maximumCommandCount: 4,
                maximumTotalStrokePointCount: 8,
                maximumSerializedStorageBytes: 32 * 1024
            ),
            stroke: duplicateStroke,
            expected: .duplicateCommandIdentifier(duplicateID)
        )
    }

    @Test func recordRenderedStrokeCannotCreateAnInvalidProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let duplicateID = UUID(uuidString: "E020FB42-DA9A-40F5-B6C7-B720FB3E7D59")!
        var project = PaintingProject.testCanvas(64)
        project.commands = [
            .clearLayer(LayerCommand(id: duplicateID, layerID: UUID()))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let duplicateStroke = StrokeCommand.testDot(
            id: duplicateID,
            layerID: project.layers[0].id
        )

        #expect(
            throws: RendererError.invalidProject(.duplicateCommandIdentifier(duplicateID))
        ) {
            try renderer.recordRenderedStroke(duplicateStroke)
        }
        #expect(renderer.project == project)
    }

    @Test func rendererCapacityTracksEightAndTwelveLiveLayers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        func project(layerCount: Int) -> PaintingProject {
            PaintingProject(
                canvas: CanvasSize(width: 64, height: 64),
                paper: .coldPress,
                layers: (1...layerCount).map { PaintLayer(name: "Layer \($0)") }
            )
        }

        let eight = try WatercolorRenderer(project: project(layerCount: 8), device: device)
        let twelve = try WatercolorRenderer(project: project(layerCount: 12), device: device)

        #expect(eight.debugResources.pigmentArrayLength == 8)
        #expect(eight.debugResources.wetnessArrayLength == 8)
        #expect(twelve.debugResources.pigmentArrayLength == 12)
        #expect(twelve.debugResources.wetnessArrayLength == 12)
    }

    @Test func maximumCanvasTwelveLayerTextureEstimateExceedsCheckpointBudget() {
        let estimatedBytes = WatercolorRenderer.estimatedTextureBytes(
            width: 4096,
            height: 4096,
            layerCapacity: 12
        )

        #expect(estimatedBytes == 4_160_749_568)
        #expect(estimatedBytes > 256 * 1024 * 1024)
    }

    @Test func checkpointEstimateIncludesReusablePreviewSnapshots() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let liveTextureBytes = WatercolorRenderer.estimatedTextureBytes(
            width: project.canvas.width,
            height: project.canvas.height,
            layerCapacity: 1
        )
        let previewSnapshotBytes = project.canvas.width * project.canvas.height
            * RendererResourcePolicy.previewSnapshotBytesPerPixel

        #expect(renderer.estimatedResourceBytes >= liveTextureBytes + previewSnapshotBytes)
    }

    @Test func benchmark1600By1200AtEightAndTwelveLayers() throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_BENCHMARK"] == "1",
              let device = MTLCreateSystemDefaultDevice()
        else { return }

        for layerCount in [8, 12] {
            let layers = (1...layerCount).map { PaintLayer(name: "Layer \($0)") }
            let project = PaintingProject(
                canvas: CanvasSize(width: 1600, height: 1200),
                paper: .rough,
                layers: layers
            )
            let allocationStart = ProcessInfo.processInfo.systemUptime
            let renderer = try WatercolorRenderer(project: project, device: device)
            let allocationDuration = ProcessInfo.processInfo.systemUptime - allocationStart
            var stroke = StrokeCommand.testDot(layerID: layers[0].id)
            stroke.points = (0...32).map { index in
                let progress = Double(index) / 32
                return StrokePoint(
                    x: 200 + 1200 * progress,
                    y: 600 + sin(progress * .pi * 2) * 100,
                    pressure: 0.8,
                    tiltX: 0,
                    tiltY: 0,
                    time: progress
                )
            }
            let strokeStart = ProcessInfo.processInfo.systemUptime
            try renderer.renderAndWait(stroke: stroke)
            let strokeDuration = ProcessInfo.processInfo.systemUptime - strokeStart
            let dispatch = renderer.debugLastStrokeDispatch

            print(
                "WATERCOLOR_BENCHMARK layers=\(layerCount) "
                    + "allocation_replay_ms=\(Int((allocationDuration * 1000).rounded())) "
                    + "stroke_ms=\(Int((strokeDuration * 1000).rounded())) "
                    + "simulation_threads=\(dispatch.simulationThreadCount)"
            )
            #expect(renderer.debugResources.pigmentArrayLength == layerCount)
            #expect(dispatch.activeSliceDepth == 1)
            #expect(try renderer.compositeChecksum() != 0)
        }
    }

    @Test func benchmarkConfiguredMaximumPreviewCommitAndCancelLatency() async throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_BENCHMARK"] == "1",
              let device = MTLCreateSystemDefaultDevice()
        else { return }

        let configuredMaximumPointCount = 512
        let project = PaintingProject.testCanvas(64)
        let admissionLimits = ProjectAdmissionLimits(
            maximumCommandCount: 4,
            maximumTotalStrokePointCount: configuredMaximumPointCount,
            maximumSerializedStorageBytes: 256 * 1024
        )
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        stroke.brush.size = 4
        stroke.points = (0..<configuredMaximumPointCount).map { index in
            let progress = Double(index) / Double(configuredMaximumPointCount - 1)
            return StrokePoint(
                x: 8 + progress * 48,
                y: 32 + sin(progress * .pi * 8) * 16,
                pressure: 0.8,
                tiltX: 0,
                tiltY: 0,
                time: progress
            )
        }
        var initial = stroke
        initial.points = [stroke.points[0]]

        let commitRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: admissionLimits,
            debugCommandBufferError: { $0.error }
        )
        let commitToken = try commitRenderer.beginStrokePreview(initial)
        let encodeStart = ProcessInfo.processInfo.systemUptime
        try await commitRenderer.appendStrokePreview(
            id: stroke.id,
            points: Array(stroke.points.dropFirst()),
            token: commitToken
        )
        let encodeMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000
        let commitStart = ProcessInfo.processInfo.systemUptime
        try await commitRenderer.finishStrokePreview(stroke, token: commitToken)
        let terminalPointCount = commitRenderer.debugLastPreviewFinishEncodedPointCount
        try commitRenderer.recordRenderedStroke(stroke)
        let commitMilliseconds = (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000

        let cancelRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugProjectAdmissionLimits: admissionLimits,
            debugCommandBufferError: { $0.error }
        )
        let checksumBeforeCancel = try cancelRenderer.compositeChecksum()
        let cancelToken = try cancelRenderer.beginStrokePreview(initial)
        try await cancelRenderer.appendStrokePreview(
            id: stroke.id,
            points: Array(stroke.points.dropFirst()),
            token: cancelToken
        )
        let cancelStart = ProcessInfo.processInfo.systemUptime
        try await cancelRenderer.restoreStrokePreviewCancellation(cancelToken)
        let cancelMilliseconds = (ProcessInfo.processInfo.systemUptime - cancelStart) * 1_000

        print(
            "WATERCOLOR_RESOURCE_LATENCY phase=preview_transaction "
                + "configured_max_points=\(configuredMaximumPointCount) "
                + "terminal_points=\(terminalPointCount) "
                + "encode_ms=\(String(format: "%.3f", encodeMilliseconds)) "
                + "commit_ms=\(String(format: "%.3f", commitMilliseconds)) "
                + "cancel_ms=\(String(format: "%.3f", cancelMilliseconds))"
        )
        #expect(commitRenderer.project.commands == [.stroke(stroke)])
        #expect((1...8).contains(terminalPointCount))
        #expect(try cancelRenderer.compositeChecksum() == checksumBeforeCancel)
        #expect(encodeMilliseconds < 2_000)
        #expect(commitMilliseconds < 2_000)
        #expect(cancelMilliseconds < 2_000)
    }

    @Test func strokeSimulationUsesBatchesPaddedDirtyRegionsAndActiveSlices() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(256, paper: .rough)
        project.layers.append(contentsOf: (2...12).map { PaintLayer(name: "Layer \($0)") })
        let renderer = try WatercolorRenderer(project: project, device: device)
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id, x: 128, y: 128)
        stroke.points = (0..<17).map { index in
            StrokePoint(
                x: Double(112 + index * 2),
                y: 128,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }

        try renderer.renderAndWait(stroke: stroke)
        let dispatch = renderer.debugLastStrokeDispatch

        #expect(dispatch.stampBatchCount == 3)
        #expect(dispatch.simulationStepCount == 34)
        #expect(dispatch.activeSliceDepth == 1)
        #expect(dispatch.simulationRegion.width < CGFloat(project.canvas.width))
        #expect(dispatch.simulationRegion.height < CGFloat(project.canvas.height))
        #expect(dispatch.simulationThreadCount < project.canvas.width * project.canvas.height * 34)
    }

    @Test func distantStrokesKeepSeparateDirtyRegionsAndAdvanceOnlyExplicitWetSlices() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layers = [PaintLayer(name: "First wet layer"), PaintLayer(name: "Dry layer"), PaintLayer(name: "Second wet layer")]
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: layers
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        try renderer.renderAndWait(stroke: .testDot(layerID: layers[0].id, tool: .water, x: 32, y: 32))
        let firstWetness = try renderer.debugWetness(x: 32, y: 32, layerID: layers[0].id)

        try renderer.renderAndWait(stroke: .testDot(layerID: layers[2].id, tool: .water, x: 224, y: 224))
        let dispatch = renderer.debugLastStrokeDispatch

        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: layers[0].id) < firstWetness)
        #expect(dispatch.activeSliceDepth == 2)
        #expect(dispatch.simulationRegion.width < 96)
        #expect(dispatch.simulationRegion.height < 96)
        #expect(dispatch.simulationThreadCount < 25_000)
    }

    @Test func paperFibersModulateSimulationEvolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let strokeID = UUID(uuidString: "791115F7-61BC-4986-A16F-A8A62E684778")!
        func evolution(on paper: PaperTexture) throws -> Double {
            let project = PaintingProject.testCanvas(64, paper: paper)
            let renderer = try WatercolorRenderer(project: project, device: device)
            try renderer.renderAndWait(stroke: .testDot(
                id: strokeID,
                layerID: project.layers[0].id,
                tool: .water
            ))
            let before = try renderer.debugWetness(x: 32, y: 32)
            try renderer.dry(layerID: project.layers[0].id, steps: 1)
            return try renderer.debugWetness(x: 32, y: 32) / before
        }

        let hotPress = try evolution(on: .hotPress)
        let rough = try evolution(on: .rough)

        #expect(abs(hotPress - rough) > 0.000_1)
    }

    @Test func structuralCandidatesShareCompiledPipelinesButOwnTheirTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var structuralProject = project
        structuralProject.layers.append(PaintLayer(name: "Second"))

        let candidate = try renderer.makeCandidate(project: structuralProject)

        #expect(candidate.debugResources.pipelines == renderer.debugResources.pipelines)
        #expect(
            Set(candidate.debugResources.pigmentTextures)
                .isDisjoint(with: Set(renderer.debugResources.pigmentTextures))
        )
        #expect(
            candidate.debugResources.compositeTextures
                .isDisjoint(with: renderer.debugResources.compositeTextures)
        )
    }

    @Test func activeMultilayerPreviewIsChargedBeforeCandidateAllocation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = PaintLayer(name: "First")
        let second = PaintLayer(name: "Second")
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [first, second]
        )
        let exactRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugResourcePolicy: RendererResourcePolicy(maximumWorkingSetBytes: 10_224_008)
        )
        let exactToken = try exactRenderer.beginStrokePreview(.testDot(layerID: first.id))
        var candidateProject = project
        candidateProject.layers.append(PaintLayer(name: "Third"))

        _ = try exactRenderer.makeCandidate(project: candidateProject)
        try exactRenderer.cancelStrokePreview(exactToken)

        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugResourcePolicy: RendererResourcePolicy(maximumWorkingSetBytes: 10_224_007)
        )
        let token = try renderer.beginStrokePreview(.testDot(layerID: first.id))

        #expect(
            throws: RendererError.resourceBudgetExceeded(
                required: 10_224_008,
                available: 10_224_007
            )
        ) {
            _ = try renderer.makeCandidate(project: candidateProject)
        }

        try renderer.cancelStrokePreview(token)
    }

    @Test func previewDefersIncompleteCanonicalBatchUntilFinish() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        stroke.points = (0..<8).map { index in
            StrokePoint(
                x: Double(8 + index),
                y: 16,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        stroke.points.append(StrokePoint(
            x: 52,
            y: 48,
            pressure: 1,
            tiltX: 0,
            tiltY: 0,
            time: 8
        ))

        var initial = stroke
        initial.points = [stroke.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: stroke.id,
            points: Array(stroke.points[1...]),
            token: token
        )

        #expect(try renderer.debugPixel(x: 52, y: 48).alpha == 0)

        try await renderer.finishStrokePreview(stroke, token: token)
        #expect(try renderer.debugPixel(x: 52, y: 48).alpha > 0.05)
    }

    @Test(arguments: [8, 16])
    func exactCanonicalBatchEndpointFieldsMatchFreshAndReopenedReplay(
        pointCount: Int
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(256)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var sampled = StrokeCommand.testDot(
            id: UUID(uuidString: "E9240BED-AB21-42D0-A18F-F75A12206AB9")!,
            layerID: project.layers[0].id
        )
        sampled.points = (0..<pointCount).map { index in
            StrokePoint(
                x: Double(32 + index * 10),
                y: 128,
                pressure: index == pointCount - 1 ? 0.1 : 0.65,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var pointerUp = sampled
        pointerUp.points[pointCount - 1] = StrokePoint(
            x: sampled.points[pointCount - 1].x,
            y: sampled.points[pointCount - 1].y,
            pressure: 1,
            tiltX: 0.75,
            tiltY: -0.5,
            time: Double(pointCount) + 0.5
        )
        var initial = sampled
        initial.points = [sampled.points[0]]

        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: sampled.id,
            points: Array(sampled.points.dropFirst()),
            token: token
        )
        try await renderer.finishStrokePreview(pointerUp, token: token)
        let liveChecksum = try renderer.compositeChecksum()

        var replayProject = project
        replayProject.commands = [.stroke(pointerUp)]
        let fresh = try WatercolorRenderer(project: replayProject, device: device)
        let reopenedProject = try PaintingDocumentCodec.decode(
            PaintingDocumentCodec.encode(replayProject)
        )
        let reopened = try WatercolorRenderer(project: reopenedProject, device: device)

        #expect(liveChecksum == (try fresh.compositeChecksum()))
        #expect(liveChecksum == (try reopened.compositeChecksum()))
    }

    @Test func incrementalPreviewBatchesMatchPreFinishFinishAndFreshReplay() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(256)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var complete = StrokeCommand.testDot(
            id: UUID(uuidString: "3EC4C328-5F44-4661-95A3-B8BB361D8B91")!,
            layerID: project.layers[0].id
        )
        complete.points = []
        for index in 0..<24 {
            complete.points.append(StrokePoint(
                x: Double(24 + index * 8),
                y: Double(96 + index % 3),
                pressure: 0.5 + Double(index % 2) * 0.4,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 60
            ))
        }
        var initial = complete
        initial.points = [complete.points[0]]

        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[1..<5]),
            token: token
        )
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[5..<14]),
            token: token
        )
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[14..<24]),
            token: token
        )
        let preFinishChecksum = try renderer.compositeChecksum()

        var replayProject = project
        var prefix = complete
        prefix.points = Array(complete.points.prefix(16))
        replayProject.commands = [.stroke(prefix)]
        let replayedPrefix = try WatercolorRenderer(project: replayProject, device: device)
        #expect(preFinishChecksum == (try replayedPrefix.compositeChecksum()))

        try await renderer.finishStrokePreview(complete, token: token)
        replayProject.commands = [.stroke(complete)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func incrementalPreviewKeepsOnlyCanonicalRemainderUntilFinish() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(256)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.points = (0..<19).map { index in
            StrokePoint(
                x: Double(32 + index * 8), y: 128, pressure: 1,
                tiltX: 0, tiltY: 0, time: Double(index)
            )
        }
        var initial = complete
        initial.points = [complete.points[0]]

        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[1...]),
            token: token
        )

        var prefixProject = project
        var prefix = complete
        prefix.points = Array(complete.points.prefix(16))
        prefixProject.commands = [.stroke(prefix)]
        let replayedPrefix = try WatercolorRenderer(project: prefixProject, device: device)
        #expect(try renderer.compositeChecksum() == replayedPrefix.compositeChecksum())

        try await renderer.finishStrokePreview(complete, token: token)
        var fullProject = project
        fullProject.commands = [.stroke(complete)]
        let replayedFull = try WatercolorRenderer(project: fullProject, device: device)
        #expect(try renderer.compositeChecksum() == replayedFull.compositeChecksum())
    }

    @Test func incrementalSmearUsesThePriorPointAcrossCanonicalBatches() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(256)
        project.commands = [
            .stroke(.testDot(layerID: project.layers[0].id, x: 104, y: 128))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.tool = .smear
        complete.points = (0..<16).map { index in
            StrokePoint(
                x: Double(72 + index * 5), y: 128, pressure: 1,
                tiltX: 0, tiltY: 0, time: Double(index)
            )
        }
        var initial = complete
        initial.points = [complete.points[0]]

        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[1..<10]),
            token: token
        )
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[10..<16]),
            token: token
        )
        let previewChecksum = try renderer.compositeChecksum()

        var replayProject = project
        var prefix = complete
        prefix.points = Array(complete.points.prefix(8))
        replayProject.commands.append(.stroke(prefix))
        let replayedPrefix = try WatercolorRenderer(project: replayProject, device: device)
        #expect(previewChecksum == (try replayedPrefix.compositeChecksum()))

        try await renderer.finishStrokePreview(complete, token: token)
        replayProject.commands[replayProject.commands.count - 1] = .stroke(complete)
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test(
        arguments: [PaintTool.brush, .smudge, .smear],
        [1, 2, 3, 4, 5, 6, 7, 8]
    )
    func previewFinishEncodesOnlyTheUnpreviewedCanonicalRemainder(
        tool: PaintTool,
        trailingPointCount: Int
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pointCount = 16 + trailingPointCount
        var project = PaintingProject.testCanvas(128)
        project.commands = [
            .stroke(.testDot(
                id: UUID(uuidString: "494B919D-5FB1-49BE-A8C5-E970A9F9C1ED")!,
                layerID: project.layers[0].id,
                x: 64,
                y: 64
            ))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        var complete = StrokeCommand.testDot(
            id: UUID(uuidString: "5DD4CDB3-F584-4322-A19D-68BFC85B298A")!,
            layerID: project.layers[0].id
        )
        complete.tool = tool
        var points: [StrokePoint] = []
        for index in 0..<pointCount {
            points.append(StrokePoint(
                x: Double(24 + index * 4),
                y: Double(64 + index % 3),
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            ))
        }
        complete.points = points
        var initial = complete
        initial.points = [complete.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points.dropFirst()),
            token: token
        )

        var prefixProject = project
        var prefix = complete
        prefix.points = Array(complete.points.prefix(pointCount - trailingPointCount))
        if !prefix.points.isEmpty {
            prefixProject.commands.append(.stroke(prefix))
        }
        let freshPrefix = try WatercolorRenderer(project: prefixProject, device: device)
        let preFinishChecksum = try renderer.compositeChecksum()
        #expect(preFinishChecksum == (try freshPrefix.compositeChecksum()))

        try await renderer.finishStrokePreview(complete, token: token)

        var completedProject = project
        completedProject.commands.append(.stroke(complete))
        let freshCompleted = try WatercolorRenderer(project: completedProject, device: device)
        #expect(renderer.debugLastPreviewFinishEncodedPointCount == trailingPointCount)
        #expect(try renderer.compositeChecksum() == freshCompleted.compositeChecksum())
    }

    @Test func emptyIncrementalPreviewDeltaDoesNotSubmitGPUWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        var previewSubmissions = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor stroke preview" {
                    previewSubmissions += 1
                }
                return commandBuffer.error
            }
        )
        let stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        let token = try renderer.beginStrokePreview(stroke)

        try await renderer.appendStrokePreview(id: stroke.id, points: [], token: token)

        #expect(previewSubmissions == 0)
        try renderer.cancelStrokePreview(token)
    }

    @Test func failedCanonicalAppendRejectsFinishUntilCancelledAndDoesNotPoisonRecovery() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 12_000,
                maximumProjectThreads: 1_000_000
            )
        )
        let checksumBefore = try renderer.compositeChecksum()
        var failedStroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        failedStroke.brush.size = 24
        failedStroke.points = (0..<9).map { index in
            StrokePoint(
                x: 8 + Double(index) * (48.0 / 7.0),
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = failedStroke
        initial.points = [failedStroke.points[0]]

        let failedToken = try renderer.beginStrokePreview(initial)
        await #expect(
            throws: RendererError.workBudgetExceeded(required: 131_072, available: 12_000)
        ) {
            try await renderer.appendStrokePreview(
                id: failedStroke.id,
                points: Array(failedStroke.points[1...]),
                token: failedToken
            )
        }
        await #expect(throws: RendererError.invalidStrokePreview) {
            try await renderer.finishStrokePreview(failedStroke, token: failedToken)
        }
        try renderer.cancelStrokePreview(failedToken)
        #expect(try renderer.compositeChecksum() == checksumBefore)

        let recovery = StrokeCommand.testDot(layerID: project.layers[0].id)
        let recoveryToken = try renderer.beginStrokePreview(recovery)
        try await renderer.finishStrokePreview(recovery, token: recoveryToken)
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func previewWorkBudgetSpansEveryDeltaInOneSemanticStroke() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let workPolicy = RendererWorkPolicy(
            maximumCommandThreads: 140_000,
            maximumProjectThreads: 140_000
        )
        var splitSubmissions = 0
        let splitRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: workPolicy,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor stroke preview" {
                    splitSubmissions += 1
                }
                return commandBuffer.error
            }
        )
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.points = (0..<17).map { index in
            StrokePoint(
                x: 32,
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = complete
        initial.points = [complete.points[0]]
        let checksumBefore = try splitRenderer.compositeChecksum()
        let splitToken = try splitRenderer.beginStrokePreview(initial)

        try await splitRenderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[1..<9]),
            token: splitToken
        )
        let admittedPrefixChecksum = try splitRenderer.compositeChecksum()
        #expect(splitSubmissions == 1)

        await #expect(throws: RendererError.self) {
            try await splitRenderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[9..<17]),
                token: splitToken
            )
        }
        #expect(splitSubmissions == 1)
        #expect(try splitRenderer.compositeChecksum() == admittedPrefixChecksum)
        try splitRenderer.cancelStrokePreview(splitToken)
        #expect(try splitRenderer.compositeChecksum() == checksumBefore)

        var singleSubmissionCount = 0
        let singleRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: workPolicy,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor stroke preview" {
                    singleSubmissionCount += 1
                }
                return commandBuffer.error
            }
        )
        let singleToken = try singleRenderer.beginStrokePreview(initial)
        await #expect(throws: RendererError.self) {
            try await singleRenderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[1..<17]),
                token: singleToken
            )
        }
        #expect(singleSubmissionCount == 0)
        #expect(try singleRenderer.compositeChecksum() == checksumBefore)
        try singleRenderer.cancelStrokePreview(singleToken)

        var finishSubmissionCount = 0
        let finishRenderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: workPolicy,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Commit watercolor stroke preview" {
                    finishSubmissionCount += 1
                }
                return commandBuffer.error
            }
        )
        var prefixThenTail = complete
        prefixThenTail.points = Array(complete.points.prefix(9))
        var finishInitial = prefixThenTail
        finishInitial.points = [prefixThenTail.points[0]]
        let finishToken = try finishRenderer.beginStrokePreview(finishInitial)
        try await finishRenderer.appendStrokePreview(
            id: prefixThenTail.id,
            points: Array(prefixThenTail.points.dropFirst()),
            token: finishToken
        )

        await #expect(
            throws: RendererError.workBudgetExceeded(required: 147_456, available: 140_000)
        ) {
            try await finishRenderer.finishStrokePreview(prefixThenTail, token: finishToken)
        }
        #expect(finishSubmissionCount == 0)
        #expect(try finishRenderer.compositeChecksum() == checksumBefore)
    }

    @Test func overlappingAppendIsRejectedWithoutReusingTheInFlightBatchOffset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(128)
        let gate = RendererPreviewUpdateGate()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugPreviewAppendWillCommit: {
                await gate.suspendOnce()
            }
        )
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.points = (0..<17).map { index in
            StrokePoint(
                x: Double(16 + index * 6),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = complete
        initial.points = [complete.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        let firstAppend = Task { @MainActor in
            try await renderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[1..<9]),
                token: token
            )
        }
        await gate.waitUntilSuspended()

        await #expect(throws: RendererError.invalidStrokePreview) {
            try await renderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[9..<17]),
                token: token
            )
        }
        await gate.resume()
        try await firstAppend.value
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[9..<17]),
            token: token
        )
        try await renderer.finishStrokePreview(complete, token: token)

        var replayProject = project
        replayProject.commands = [.stroke(complete)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func finishIsRejectedWhileAppendIsInFlightThenSucceedsAfterAppendCommits() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(128)
        let gate = RendererPreviewUpdateGate()
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugPreviewAppendWillCommit: {
                await gate.suspendOnce()
            }
        )
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.points = (0..<9).map { index in
            StrokePoint(
                x: Double(24 + index * 8),
                y: 64,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = complete
        initial.points = [complete.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        let append = Task { @MainActor in
            try await renderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[1...]),
                token: token
            )
        }
        await gate.waitUntilSuspended()

        await #expect(throws: RendererError.invalidStrokePreview) {
            try await renderer.finishStrokePreview(complete, token: token)
        }
        await gate.resume()
        try await append.value
        try await renderer.finishStrokePreview(complete, token: token)

        var replayProject = project
        replayProject.commands = [.stroke(complete)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func finalStrokeIntegrityRejectsSequenceChangesAndAcceptsEndpointFieldReplacement() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var complete = StrokeCommand.testDot(layerID: project.layers[0].id)
        complete.points = (0..<4).map { index in
            StrokePoint(
                x: Double(16 + index * 8),
                y: 32,
                pressure: 0.5,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var missing = complete
        missing.points.removeLast()
        var extra = complete
        extra.points.append(StrokePoint(
            x: 48, y: 32, pressure: 0.5, tiltX: 0, tiltY: 0, time: 4
        ))
        var reordered = complete
        reordered.points.swapAt(1, 2)
        var changedPrefix = complete
        changedPrefix.points[1].pressure = 0.75

        for invalid in [missing, extra, reordered, changedPrefix] {
            var initial = complete
            initial.points = [complete.points[0]]
            let token = try renderer.beginStrokePreview(initial)
            try await renderer.appendStrokePreview(
                id: complete.id,
                points: Array(complete.points[1...]),
                token: token
            )
            await #expect(throws: RendererError.invalidStrokePreview) {
                try await renderer.finishStrokePreview(invalid, token: token)
            }
            try renderer.cancelStrokePreview(token)
        }

        var finalReplacement = complete
        finalReplacement.points[3].pressure = 0.9
        finalReplacement.points[3].tiltX = 0.5
        finalReplacement.points[3].tiltY = -0.25
        finalReplacement.points[3].time = 4
        var initial = complete
        initial.points = [complete.points[0]]
        let acceptedToken = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: complete.id,
            points: Array(complete.points[1...]),
            token: acceptedToken
        )
        try await renderer.finishStrokePreview(finalReplacement, token: acceptedToken)

        var replayProject = project
        replayProject.commands = [.stroke(finalReplacement)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)
        #expect(try renderer.compositeChecksum() == replayed.compositeChecksum())
    }

    @Test func selectedOnlyCompletedPreviewMatchesFinishAndReplay() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        stroke.points = (0..<8).map { index in
            StrokePoint(
                x: Double(16 + index * 4),
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }

        var initial = stroke
        initial.points = [stroke.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        let checksumBefore = try renderer.compositeChecksum()
        try await renderer.appendStrokePreview(
            id: stroke.id,
            points: Array(stroke.points[1...]),
            token: token
        )
        let previewChecksum = try renderer.compositeChecksum()
        try await renderer.finishStrokePreview(stroke, token: token)
        let finishedChecksum = try renderer.compositeChecksum()
        var replayProject = project
        replayProject.commands = [.stroke(stroke)]
        let replayed = try WatercolorRenderer(project: replayProject, device: device)

        #expect(previewChecksum == checksumBefore)
        #expect(finishedChecksum != previewChecksum)
        #expect(finishedChecksum == (try replayed.compositeChecksum()))
    }

    @Test func cancellingMultilayerPreviewReplaysNonSelectedEvolution() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = PaintLayer(name: "Wet")
        let second = PaintLayer(name: "Preview")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [first, second]
        )
        project.commands = [
            .stroke(.testDot(layerID: first.id, x: 16, y: 16)),
            .dryLayer(DryLayerCommand(layerID: first.id, steps: 250))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let checksumBefore = try renderer.compositeChecksum()
        let wetnessBefore = try renderer.debugWetness(x: 16, y: 16, layerID: first.id)
        var preview = StrokeCommand.testDot(layerID: second.id)
        preview.points = (0..<9).map { index in
            StrokePoint(
                x: Double(32 + index * 3),
                y: 40,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }

        var initial = preview
        initial.points = [preview.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: preview.id,
            points: Array(preview.points[1...]),
            token: token
        )

        #expect(try renderer.debugWetness(x: 16, y: 16, layerID: first.id) < wetnessBefore)
        try renderer.cancelStrokePreview(token)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugWetness(x: 16, y: 16, layerID: first.id) == wetnessBefore)
    }

    @Test func asynchronousCancellationNeverUsesACommandBufferBlockingWait() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var preview = StrokeCommand.testDot(layerID: project.layers[0].id)
        preview.points = (0..<8).map { index in
            StrokePoint(
                x: Double(16 + index * 4),
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = preview
        initial.points = [preview.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: preview.id,
            points: Array(preview.points.dropFirst()),
            token: token
        )

        try await renderer.restoreStrokePreviewCancellation(token)

        #expect(renderer.debugSynchronousPreviewCancellationWaitCount == 0)
    }

    @Test func asynchronousCancellationReplayNeverBlocksForGPUCompletion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let wet = PaintLayer(name: "Wet")
        let selected = PaintLayer(name: "Selected")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [wet, selected]
        )
        project.commands = [.stroke(.testDot(layerID: wet.id, x: 16, y: 16))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let checksumBefore = try renderer.compositeChecksum()
        var preview = StrokeCommand.testDot(layerID: selected.id)
        preview.points = (0..<8).map { index in
            StrokePoint(
                x: Double(32 + index * 3),
                y: 40,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var initial = preview
        initial.points = [preview.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: preview.id,
            points: Array(preview.points.dropFirst()),
            token: token
        )

        try await renderer.restoreStrokePreviewCancellation(token)

        #expect(renderer.debugSynchronousPreviewCancellationReplayCount == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
    }

    @Test func failedMultilayerPreviewFinishReplaysCommittedProject() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let first = PaintLayer(name: "Wet")
        let second = PaintLayer(name: "Preview")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [first, second]
        )
        project.commands = [.stroke(.testDot(layerID: first.id, x: 16, y: 16))]
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 73,
            userInfo: [NSLocalizedDescriptionKey: "multilayer finish failed"]
        )
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                commandBuffer.label == "Commit watercolor stroke preview"
                    ? injectedError
                    : commandBuffer.error
            }
        )
        let synchronousReplayCountBefore = renderer.debugSynchronousReplaySubmissionCount
        let checksumBefore = try renderer.compositeChecksum()
        let wetnessBefore = try renderer.debugWetness(x: 16, y: 16, layerID: first.id)
        var preview = StrokeCommand.testDot(layerID: second.id)
        preview.points = (0..<8).map { index in
            StrokePoint(
                x: Double(32 + index * 3),
                y: 40,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }

        var initial = preview
        initial.points = [preview.points[0]]
        let token = try renderer.beginStrokePreview(initial)
        try await renderer.appendStrokePreview(
            id: preview.id,
            points: Array(preview.points[1...]),
            token: token
        )

        await #expect(throws: RendererError.self) {
            try await renderer.finishStrokePreview(preview, token: token)
        }
        #expect(
            renderer.debugSynchronousReplaySubmissionCount
                == synchronousReplayCountBefore
        )
        #expect(renderer.debugSynchronousPreviewCancellationReplayCount == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugWetness(x: 16, y: 16, layerID: first.id) == wetnessBefore)
    }

    @Test func failedRemainderOnlyPreviewFinishReplaysCommittedProject() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64)
        project.commands = [.stroke(.testDot(layerID: project.layers[0].id, x: 16, y: 16))]
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 74,
            userInfo: [NSLocalizedDescriptionKey: "remainder finish failed"]
        )
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                commandBuffer.label == "Commit watercolor stroke preview"
                    ? injectedError
                    : commandBuffer.error
            }
        )
        let synchronousReplayCountBefore = renderer.debugSynchronousReplaySubmissionCount
        let checksumBefore = try renderer.compositeChecksum()
        let preview = StrokeCommand.testDot(layerID: project.layers[0].id, x: 48, y: 48)

        let token = try renderer.beginStrokePreview(preview)

        await #expect(throws: RendererError.self) {
            try await renderer.finishStrokePreview(preview, token: token)
        }
        #expect(
            renderer.debugSynchronousReplaySubmissionCount
                == synchronousReplayCountBefore
        )
        #expect(renderer.debugSynchronousPreviewCancellationWaitCount == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
    }

    @Test func replayIsDeterministic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .rough)
        project.commands = [
            .stroke(.testLine(
                id: UUID(uuidString: "82C2BD68-8748-4015-B501-D241D639A881")!,
                layerID: project.layers[0].id,
                color: PaintColor(red: 0.2, green: 0.6, blue: 0.9),
                y: 31,
                water: 0.85
            )),
            .dryLayer(DryLayerCommand(layerID: project.layers[0].id, steps: 3))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.replay(project: project)
        let first = try renderer.debugPixel(x: 29, y: 31)
        try renderer.replay(project: project)
        let second = try renderer.debugPixel(x: 29, y: 31)

        #expect(first == second)
    }

    @Test(arguments: [32, 128])
    func publicReplayRejectsCanvasDimensionChangesBeforeMutation(
        replacementSide: Int
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let checksumBefore = try renderer.compositeChecksum()
        var replacement = project
        replacement.canvas = CanvasSize(width: replacementSide, height: replacementSide)

        do {
            try renderer.replay(project: replacement)
            Issue.record("Expected dimension-changing replay to require makeCandidate")
            return
        } catch let error as RendererError {
            #expect(error == .invalidMetadataChange)
        }

        #expect(renderer.project == project)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        let preview = StrokeCommand.testDot(layerID: project.layers[0].id)
        let token = try renderer.beginStrokePreview(preview)
        try await renderer.finishStrokePreview(preview, token: token)
        let committedPreviewChecksum = try renderer.compositeChecksum()
        let secondToken = try renderer.beginStrokePreview(
            .testDot(layerID: project.layers[0].id, x: 16, y: 16)
        )
        try renderer.cancelStrokePreview(secondToken)
        #expect(try renderer.compositeChecksum() == committedPreviewChecksum)
    }

    @Test func discardedStrokeStillAdvancesSurvivingWetLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let layerID = base.layers[0].id
        var survivingStroke = StrokeCommand.testDot(
            id: UUID(uuidString: "6DF572F1-2C3C-4121-8A77-6A59A154E61F")!,
            layerID: layerID,
            color: PaintColor(red: 0.1, green: 0.4, blue: 0.8)
        )
        survivingStroke.brush.water = 0.95

        var explicitAdvance = base
        explicitAdvance.commands = [
            .stroke(survivingStroke),
            .dryLayer(DryLayerCommand(layerID: layerID, steps: 2))
        ]
        let renderer = try WatercolorRenderer(project: explicitAdvance, device: device)
        let expectedPigment = try renderer.debugPixel(x: 32, y: 32, layerID: layerID)
        let expectedWetness = try renderer.debugWetness(x: 32, y: 32, layerID: layerID)

        var discardedStroke = base
        discardedStroke.commands = [
            .stroke(survivingStroke),
            .stroke(.testDot(
                id: UUID(uuidString: "E1B79612-52A7-4BEF-8E32-224B10B78E4D")!,
                layerID: UUID(uuidString: "8393575B-86A6-459F-9097-9C9D28663C7D")!
            ))
        ]
        try renderer.replay(project: discardedStroke)

        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: layerID) == expectedPigment)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: layerID) == expectedWetness)
    }

    @Test func unknownLayerProducesUsefulError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let missingID = UUID(uuidString: "06E6D10C-F2B3-4BC4-B7BA-31067132045D")!

        #expect(throws: RendererError.unknownLayer(missingID)) {
            try renderer.render(stroke: .testDot(layerID: missingID))
        }
    }

    @Test func rendererRejectsUnsafeStrokeNumbersInsteadOfConvertingThemToIntegers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let stroke = StrokeCommand.testDot(layerID: project.layers[0].id, x: 1e300, y: 32)

        #expect(throws: RendererError.invalidProject(.invalidStrokePoint(stroke.id, 0))) {
            try renderer.render(stroke: stroke)
        }
    }

    @Test func rendererRejectsUnboundedDryReplayBeforeDispatchingWork() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var unsafe = project
        let command = DryLayerCommand(
            layerID: project.layers[0].id,
            steps: PaintingProject.maximumDryStepCount + 1
        )
        unsafe.commands = [.dryLayer(command)]

        #expect(throws: RendererError.invalidProject(.invalidDryStepCount(command.id, command.steps))) {
            try renderer.replay(project: unsafe)
        }
    }

    @Test func dryWorkRejectionSubmitsNoReplayAndLeavesRendererUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 6_000,
                maximumProjectThreads: 1_000_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        let checksumBefore = try renderer.compositeChecksum()
        var hostile = original
        hostile.commands = [
            .stroke(.testDot(layerID: original.layers[0].id)),
            .dryLayer(DryLayerCommand(layerID: original.layers[0].id, steps: 100))
        ]

        #expect(
            throws: RendererError.workBudgetExceeded(required: 819_200, available: 6_000)
        ) {
            try renderer.replay(project: hostile)
        }

        #expect(replaySubmissions == 0)
        #expect(renderer.project == original)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        try renderer.renderAndWait(stroke: .testDot(layerID: original.layers[0].id))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func liveStrokeWorkRejectionSubmitsNothingAndPreservesState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        var strokeSubmissions = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 6_000,
                maximumProjectThreads: 1_000_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor stroke" {
                    strokeSubmissions += 1
                }
                return commandBuffer.error
            }
        )
        let checksumBefore = try renderer.compositeChecksum()
        var hostile = StrokeCommand.testDot(layerID: project.layers[0].id, x: 10)
        hostile.points.append(StrokePoint(
            x: 54,
            y: 32,
            pressure: 1,
            tiltX: 0,
            tiltY: 0,
            time: 1
        ))

        #expect(
            throws: RendererError.workBudgetExceeded(required: 21_504, available: 6_000)
        ) {
            try renderer.renderAndWait(stroke: hostile)
        }

        #expect(strokeSubmissions == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func previewFinishWorkAdmissionFailureResolvesTheTransaction() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        var finishSubmissions = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 12_000,
                maximumProjectThreads: 1_000_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Commit watercolor stroke preview" {
                    finishSubmissions += 1
                }
                return commandBuffer.error
            }
        )
        let checksumBefore = try renderer.compositeChecksum()
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id, x: 8)

        let token = try renderer.beginStrokePreview(stroke)
        let appendedPoint = StrokePoint(
            x: 56,
            y: 32,
            pressure: 1,
            tiltX: 0,
            tiltY: 0,
            time: 1
        )
        stroke.points.append(appendedPoint)
        try await renderer.appendStrokePreview(
            id: stroke.id,
            points: [appendedPoint],
            token: token
        )
        finishSubmissions = 0

        await #expect(
            throws: RendererError.workBudgetExceeded(required: 21_504, available: 12_000)
        ) {
            try await renderer.finishStrokePreview(stroke, token: token)
        }

        #expect(finishSubmissions == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        try renderer.cancelStrokePreview(token)

        let recovery = StrokeCommand.testDot(layerID: project.layers[0].id)
        let recoveryToken = try renderer.beginStrokePreview(recovery)
        try await renderer.finishStrokePreview(recovery, token: recoveryToken)
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func directDryWorkAdmissionFailurePreservesState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        var drySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 8_000,
                maximumProjectThreads: 1_000_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Dry watercolor layer" {
                    drySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id))
        let checksumBefore = try renderer.compositeChecksum()

        #expect(
            throws: RendererError.workBudgetExceeded(required: 819_200, available: 8_000)
        ) {
            try renderer.dry(layerID: project.layers[0].id, steps: 100)
        }

        #expect(drySubmissions == 0)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func initializerWorkAdmissionRejectsBeforeReplaySubmission() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        var hostile = base
        hostile.commands = [
            .stroke(.testDot(layerID: base.layers[0].id)),
            .dryLayer(DryLayerCommand(layerID: base.layers[0].id, steps: 100))
        ]
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 6_000,
            maximumProjectThreads: 1_000_000
        )
        var replaySubmissions = 0

        #expect(
            throws: RendererError.workBudgetExceeded(required: 819_200, available: 6_000)
        ) {
            _ = try WatercolorRenderer(
                project: hostile,
                device: device,
                debugWorkPolicy: policy,
                debugCommandBufferError: { commandBuffer in
                    if commandBuffer.label == "Watercolor replay" {
                        replaySubmissions += 1
                    }
                    return commandBuffer.error
                }
            )
        }

        #expect(replaySubmissions == 0)
        let recovered = try WatercolorRenderer(
            project: base,
            device: device,
            debugWorkPolicy: policy
        )
        try recovered.renderAndWait(stroke: .testDot(layerID: base.layers[0].id))
        #expect(try recovered.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func candidateWorkAdmissionFailureLeavesOriginalRendererUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        let policy = RendererWorkPolicy(
            maximumCommandThreads: 6_000,
            maximumProjectThreads: 1_000_000
        )
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: policy,
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        let checksumBefore = try renderer.compositeChecksum()
        var hostile = original
        hostile.commands = [
            .stroke(.testDot(layerID: original.layers[0].id)),
            .dryLayer(DryLayerCommand(layerID: original.layers[0].id, steps: 100))
        ]

        #expect(
            throws: RendererError.workBudgetExceeded(required: 819_200, available: 6_000)
        ) {
            _ = try renderer.makeCandidate(project: hostile)
        }

        #expect(replaySubmissions == 0)
        #expect(renderer.project == original)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        try renderer.renderAndWait(stroke: .testDot(layerID: original.layers[0].id))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha > 0.1)
    }

    @Test func replayCommandBudgetAccumulatesAcrossStrokeBatches() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 140_000,
                maximumProjectThreads: 200_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        var batchedStroke = StrokeCommand.testDot(layerID: original.layers[0].id)
        batchedStroke.points = (0..<9).map { index in
            StrokePoint(
                x: 32,
                y: 32,
                pressure: 1,
                tiltX: 0,
                tiltY: 0,
                time: Double(index)
            )
        }
        var hostile = original
        hostile.commands = [.stroke(batchedStroke)]

        #expect(
            throws: RendererError.workBudgetExceeded(required: 147_456, available: 140_000)
        ) {
            try renderer.replay(project: hostile)
        }

        #expect(replaySubmissions == 0)
        #expect(renderer.project == original)
        try renderer.renderAndWait(stroke: .testDot(layerID: original.layers[0].id))
    }

    @Test func replayProjectBudgetAccumulatesAcrossPaintingCommands() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        var replaySubmissions = 0
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugWorkPolicy: RendererWorkPolicy(
                maximumCommandThreads: 6_000,
                maximumProjectThreads: 10_000
            ),
            debugCommandBufferError: { commandBuffer in
                if commandBuffer.label == "Watercolor replay" {
                    replaySubmissions += 1
                }
                return commandBuffer.error
            }
        )
        replaySubmissions = 0
        var hostile = original
        hostile.commands = [
            .stroke(.testDot(layerID: original.layers[0].id)),
            .clearLayer(LayerCommand(layerID: original.layers[0].id)),
            .stroke(.testDot(layerID: original.layers[0].id))
        ]

        #expect(
            throws: RendererError.workBudgetExceeded(required: 11_552, available: 10_000)
        ) {
            try renderer.replay(project: hostile)
        }

        #expect(replaySubmissions == 0)
        #expect(renderer.project == original)
        try renderer.renderAndWait(stroke: .testDot(layerID: original.layers[0].id))
    }

    @Test func failedCompletedStrokeDoesNotPoisonRecoveryOrTheNextStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "deterministic GPU execution failure"]
        )
        var failedBuffer: MTLCommandBuffer?
        var observedStatus: MTLCommandBufferStatus?
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
                observedStatus = commandBuffer.status
                return injectedError
            }
        )
        let checksumBefore = try renderer.compositeChecksum()

        #expect(throws: RendererError.self) {
            try renderer.renderAndWait(stroke: .testDot(
                layerID: project.layers[0].id,
                x: 20,
                y: 32
            ))
        }
        #expect(observedStatus == .completed)

        try renderer.replay(project: project)
        #expect(try renderer.compositeChecksum() == checksumBefore)

        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "FECCAE3B-FB8B-43E4-A44D-695946AFDDC1")!,
            layerID: project.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            x: 44,
            y: 32
        ))
        #expect(try renderer.debugPixel(x: 20, y: 32).alpha == 0)
        #expect(try renderer.debugPixel(x: 44, y: 32).blue > 0.1)
    }

    @Test func everyToolHasItsOwnPigmentOrWetnessEffect() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let layerID = project.layers[0].id
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testDot(layerID: layerID, tool: .water))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha == 0)
        #expect(try renderer.debugWetness(x: 32, y: 32) > 0.1)

        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID))
        let painted = try renderer.debugPixel(x: 32, y: 32).alpha
        let wet = try renderer.debugWetness(x: 32, y: 32)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .eraser))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha < painted)

        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .water))
        let waterBeforeDryTool = try renderer.debugWetness(x: 32, y: 32)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .dry))
        #expect(try renderer.debugWetness(x: 32, y: 32) < waterBeforeDryTool)

        let smudgeSignature = try transformedSignature(tool: .smudge, project: project, renderer: renderer)
        let smearSignature = try transformedSignature(tool: .smear, project: project, renderer: renderer)
        #expect(smudgeSignature != smearSignature)
        #expect(wet > 0)
    }

    @Test func smudgeUsesHorizontalAndVerticalStrokeDirectionWithoutCreatingPigment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)

        func moved(from start: StrokePoint, to end: StrokePoint) throws -> (
            before: RendererDebugPigmentMoments,
            after: RendererDebugPigmentMoments
        ) {
            let renderer = try WatercolorRenderer(project: project, device: device)
            try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id, x: 32, y: 32))
            let before = try renderer.debugPigmentMoments(layerID: project.layers[0].id)
            var brush = BrushSettings.default
            brush.size = 20
            let stroke = StrokeCommand(
                layerID: project.layers[0].id,
                tool: .smudge,
                brush: brush,
                points: [start, end]
            )
            try renderer.renderAndWait(stroke: stroke)
            return (before, try renderer.debugPigmentMoments(layerID: project.layers[0].id))
        }

        let horizontal = try moved(
            from: StrokePoint(x: 28, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 0),
            to: StrokePoint(x: 42, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )
        let vertical = try moved(
            from: StrokePoint(x: 32, y: 28, pressure: 1, tiltX: 0, tiltY: 0, time: 0),
            to: StrokePoint(x: 32, y: 42, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
        )

        #expect(horizontal.after.centroidX > horizontal.before.centroidX + 0.2)
        #expect(abs(horizontal.after.centroidY - horizontal.before.centroidY) < 0.2)
        #expect(vertical.after.centroidY > vertical.before.centroidY + 0.2)
        #expect(abs(vertical.after.centroidX - vertical.before.centroidX) < 0.2)
        let horizontalMassDelta = abs(horizontal.after.mass - horizontal.before.mass)
        let verticalMassDelta = abs(vertical.after.mass - vertical.before.mass)
        #expect(horizontalMassDelta < 0.5)
        #expect(horizontalMassDelta / horizontal.before.mass < 0.005)
        #expect(verticalMassDelta < 0.5)
        #expect(verticalMassDelta / vertical.before.mass < 0.005)
    }

    @Test func smearFollowsACurvedPathAndConservesPigmentMass() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id, x: 28, y: 28))
        let before = try renderer.debugPigmentMoments(layerID: project.layers[0].id)
        var brush = BrushSettings.default
        brush.size = 22
        let smear = StrokeCommand(
            layerID: project.layers[0].id,
            tool: .smear,
            brush: brush,
            points: [
                StrokePoint(x: 26, y: 28, pressure: 1, tiltX: 0, tiltY: 0, time: 0),
                StrokePoint(x: 38, y: 28, pressure: 1, tiltX: 0, tiltY: 0, time: 1),
                StrokePoint(x: 38, y: 40, pressure: 1, tiltX: 0, tiltY: 0, time: 2)
            ]
        )

        try renderer.renderAndWait(stroke: smear)
        let after = try renderer.debugPigmentMoments(layerID: project.layers[0].id)

        #expect(after.centroidX > before.centroidX + 0.2)
        #expect(after.centroidY > before.centroidY + 0.2)
        let absoluteMassDelta = abs(after.mass - before.mass)
        #expect(absoluteMassDelta < 0.5)
        #expect(absoluteMassDelta / before.mass < 0.005)
    }

    @Test func smudgeAtCanvasBoundaryConservesPigmentInsteadOfDiscardingOutflow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        try renderer.renderAndWait(stroke: .testDot(layerID: project.layers[0].id, x: 54, y: 32))
        let before = try renderer.debugPigmentMoments(layerID: project.layers[0].id)
        var brush = BrushSettings.default
        brush.size = 20

        try renderer.renderAndWait(stroke: StrokeCommand(
            layerID: project.layers[0].id,
            tool: .smudge,
            brush: brush,
            points: [
                StrokePoint(x: 52, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 0),
                StrokePoint(x: 63, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 1)
            ]
        ))
        let after = try renderer.debugPigmentMoments(layerID: project.layers[0].id)
        let absoluteMassDelta = abs(after.mass - before.mass)

        #expect(absoluteMassDelta < 0.5)
        #expect(absoluteMassDelta / before.mass < 0.005)
    }

    @Test func everyBrushAndPaperEnumParticipatesInDeterministicDepositSmokeCheck() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: base, device: device)

        let shapeSignatures = try BrushShape.allCases.map { shape in
            try depositSignature(project: base, renderer: renderer) { $0.shape = shape }
        }
        let hairSignatures = try BrushHair.allCases.map { hair in
            try depositSignature(project: base, renderer: renderer) { $0.hair = hair }
        }
        let textureSignatures = try BrushTexture.allCases.map { texture in
            try depositSignature(project: base, renderer: renderer) { $0.texture = texture }
        }
        let styleSignatures = try WatercolorStyle.allCases.map { style in
            try depositSignature(project: base, renderer: renderer) { $0.style = style }
        }
        let paperSignatures = try PaperTexture.allCases.map { paper in
            var project = base
            project.paper = paper
            return try depositSignature(project: project, renderer: renderer) { _ in }
        }
        let noBloom = try depositSignature(project: base, renderer: renderer) { $0.edgeBloom = 0 }
        let fullBloom = try depositSignature(project: base, renderer: renderer) { $0.edgeBloom = 1 }

        // Sparse signature inequality only proves each enum reaches rendering.
        // Customer-visible separation belongs to the perceptual metric tests.
        #expect(Set(shapeSignatures).count == BrushShape.allCases.count)
        #expect(Set(hairSignatures).count == BrushHair.allCases.count)
        #expect(Set(textureSignatures).count == BrushTexture.allCases.count)
        #expect(Set(styleSignatures).count == WatercolorStyle.allCases.count)
        #expect(Set(paperSignatures).count == PaperTexture.allCases.count)
        #expect(noBloom != fullBloom)
    }

    @Test func canonicalRendererPhenotypeMetricsAreFiniteAndStable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

        for fixture in canonicalPhenotypeFixtures() {
            let first = try renderPhenotypeMetrics(fixture, device: device)
            let second = try renderPhenotypeMetrics(fixture, device: device)

            for metrics in [first, second] {
                for value in phenotypeMetricScalars(metrics) {
                    #expect(value.isFinite, "\(fixture.name) produced a non-finite metric")
                }
                #expect(metrics.area > 0, "\(fixture.name) produced an empty coverage mask")
                #expect(metrics.pigmentMass > 0, "\(fixture.name) produced no pigment")
                #expect(metrics.wetnessMass > 0, "\(fixture.name) produced no wetness")
                #expect(metrics.spreadRadius > 0, "\(fixture.name) produced no spatial spread")
                #expect(metrics.edgeRoughness > 0, "\(fixture.name) produced no measurable edge")
                #expect(metrics.laneCount > 0, "\(fixture.name) produced no persistent lane")
            }
            expectStablePhenotypeMetrics(first, second, fixtureName: fixture.name)
            print("Brush phenotype characterization [\(fixture.name)]: \(phenotypeDiagnostics(first))")
        }
    }

    @Test func layerVisibilityOpacityAndOrderAffectComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(
            id: UUID(uuidString: "728C677B-6290-4433-B161-06622DD8D541")!,
            name: "Bottom"
        )
        let top = PaintLayer(
            id: UUID(uuidString: "0941726A-63AA-4089-A251-C9B0DD2A8652")!,
            name: "Top"
        )
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let blueOnTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers[1].isVisible = false
        try renderer.replay(project: project)
        let hiddenTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers[1].isVisible = true
        project.layers[1].opacity = 0.2
        try renderer.replay(project: project)
        let translucentTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers = [top, bottom]
        project.layers[0].opacity = 1
        try renderer.replay(project: project)
        let redOnTop = try renderer.compositePixel(x: 32, y: 32)

        #expect(blueOnTop.blue > hiddenTop.blue)
        #expect(hiddenTop.red > blueOnTop.red)
        #expect(translucentTop.blue > hiddenTop.blue)
        #expect(translucentTop.blue < blueOnTop.blue)
        #expect(redOnTop.red > redOnTop.blue)
    }

    @Test func layerOpacityPreviewRecompositesWithoutChangingTheProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = try renderer.compositePixel(x: 32, y: 32)

        try renderer.previewLayerOpacity(id: top.id, opacity: 0.1)
        let preview = try renderer.compositePixel(x: 32, y: 32)

        #expect(renderer.project == project)
        #expect(preview.blue < before.blue)
        #expect(preview.red > before.red)

        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositePixel(x: 32, y: 32) == before)
        #expect(renderer.project == project)
    }

    @Test func metadataTransactionReusesResourcesWithoutReplayAndUpdatesTheComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let checksumBefore = try renderer.compositeChecksum()
        var updated = project
        updated.layers.reverse()
        updated.layers[0].opacity = 0.25

        try renderer.applyMetadata(project: updated)

        #expect(renderer.project == updated)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(try renderer.compositeChecksum() != checksumBefore)
    }

    @Test func metadataTransactionRejectsPaperChangesWithoutMutatingTheRenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .coldPress)
        project.commands = [.stroke(.testDot(layerID: project.layers[0].id))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let checksumBefore = try renderer.compositeChecksum()
        let pigmentBefore = try renderer.debugPixel(x: 32, y: 32, layerID: project.layers[0].id)
        let wetnessBefore = try renderer.debugWetness(x: 32, y: 32, layerID: project.layers[0].id)
        var updated = project
        updated.paper = .rough

        #expect(throws: RendererError.invalidMetadataChange) {
            try renderer.applyMetadata(project: updated)
        }

        #expect(renderer.project == project)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: project.layers[0].id) == pigmentBefore)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: project.layers[0].id) == wetnessBefore)
    }

    @Test func failedOpacityPreviewLeavesCommittedMetadataAndAllowsTheNextPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "preview recomposite failed"]
        )
        var shouldFailPreview = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailPreview, commandBuffer.label == "Preview layer metadata" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let committedChecksum = try renderer.compositeChecksum()
        shouldFailPreview = true

        #expect(throws: RendererError.self) {
            try renderer.previewLayerOpacity(id: top.id, opacity: 0.1)
        }

        #expect(try renderer.compositeChecksum() == committedChecksum)
        shouldFailPreview = false
        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositeChecksum() == committedChecksum)

        try renderer.previewLayerOpacity(id: top.id, opacity: 0.2)
        #expect(try renderer.compositeChecksum() != committedChecksum)
        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositeChecksum() == committedChecksum)
    }

    @Test func imageReadbackKeepsCanvasTopAtFirstRow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .hotPress)
        project.commands = [
            .stroke(.testDot(
                layerID: project.layers[0].id,
                color: PaintColor(red: 1, green: 0, blue: 0),
                x: 32,
                y: 8
            )),
            .stroke(.testDot(
                layerID: project.layers[0].id,
                color: PaintColor(red: 0, green: 0, blue: 1),
                x: 32,
                y: 56
            ))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)

        let top = try renderer.compositePixel(x: 32, y: 8)
        let bottom = try renderer.compositePixel(x: 32, y: 56)

        #expect(top.red > top.blue)
        #expect(bottom.blue > bottom.red)
    }

    @Test func replayHonorsMergeAndClearCommandsInOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let destination = PaintLayer(
            id: UUID(uuidString: "86C089A3-CFFA-44F9-B7F0-57FE68572C25")!,
            name: "Destination"
        )
        let historicalSourceID = UUID(uuidString: "18B8DA86-0C8A-4E98-B7E5-232434CB3839")!
        var merged = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination]
        )
        merged.commands = [
            .stroke(.testDot(
                layerID: destination.id,
                color: PaintColor(red: 0, green: 0, blue: 1)
            )),
            .stroke(.testDot(
                layerID: historicalSourceID,
                color: PaintColor(red: 1, green: 0, blue: 0)
            )),
            .mergeDown(MergeDownCommand(
                sourceLayerID: historicalSourceID,
                destinationLayerID: destination.id
            ))
        ]
        let renderer = try WatercolorRenderer(project: merged, device: device)
        let mixed = try renderer.debugPixel(x: 32, y: 32, layerID: destination.id)
        #expect(mixed.red > 0.1)
        #expect(mixed.blue > 0.1)

        var cleared = merged
        cleared.commands.append(.clearLayer(LayerCommand(layerID: destination.id)))
        try renderer.replay(project: cleared)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: destination.id).alpha == 0)
    }

    @Test func mergeDownExcludesHiddenSourcePigment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = mergeFixture(sourceIsVisible: false, sourceOpacity: 1)

        let renderer = try WatercolorRenderer(project: project, device: device)
        let merged = try renderer.debugPixel(x: 32, y: 32, layerID: project.layers[0].id)

        #expect(merged.red < 0.01)
        #expect(merged.blue > 0.1)
    }

    @Test func mergeDownBakesTranslucentSourceOpacityIntoPigment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let translucent = try WatercolorRenderer(
            project: mergeFixture(sourceIsVisible: true, sourceOpacity: 0.25),
            device: device
        )
        let opaque = try WatercolorRenderer(
            project: mergeFixture(sourceIsVisible: true, sourceOpacity: 1),
            device: device
        )

        let translucentRed = try translucent.debugPixel(x: 32, y: 32).red
        let opaqueRed = try opaque.debugPixel(x: 32, y: 32).red
        #expect(translucentRed > 0.01)
        #expect(translucentRed < opaqueRed * 0.4)
        #expect(translucent.project.layers[0].isVisible)
        #expect(translucent.project.layers[0].opacity == 1)
    }

    @Test func compositeConvertsLinearPigmentBackToSRGBForExport() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .hotPress)
        var stroke = StrokeCommand.testDot(
            layerID: project.layers[0].id,
            color: .fromSRGB(red: 0.5, green: 0.5, blue: 0.5)
        )
        stroke.brush.opacity = 1
        stroke.brush.flow = 1
        project.commands = [.stroke(stroke)]

        let renderer = try WatercolorRenderer(project: project, device: device)
        let exported = try renderer.compositePixel(x: 32, y: 32)

        #expect(exported.red > 0.7)
        #expect(abs(exported.red - exported.green) < 0.03)
        #expect(abs(exported.green - exported.blue) < 0.03)
    }

    @Test func migratedVersionOneMidtoneReencodesAndReplaysLikeEquivalentLinearProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(
            id: UUID(uuidString: "4B60F4F3-9F6D-41B2-A99D-84CB27100D07")!,
            name: "Legacy midtone"
        )
        var legacyBrush = BrushSettings.default
        legacyBrush.color = PaintColor(red: 0.5, green: 0.25, blue: 0.75)
        let strokeID = UUID(uuidString: "C9063B47-E233-4FAF-B18D-AB71DE3EB5DB")!
        let legacyStroke = StrokeCommand.testDot(
            id: strokeID,
            layerID: layer.id,
            color: legacyBrush.color
        )
        let legacy = PaintingProject(
            schemaVersion: 1,
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer],
            commands: [.stroke(legacyStroke)]
        )

        let migrated = try PaintingDocumentCodec.decode(JSONEncoder().encode(legacy))
        let reencoded = try PaintingDocumentCodec.encode(migrated)
        let reopened = try PaintingDocumentCodec.decode(reencoded)
        var expectedStroke = legacyStroke
        expectedStroke.brush.color = .fromSRGB(red: 0.5, green: 0.25, blue: 0.75)
        expectedStroke.brush.behaviorVersion = BrushSettings.legacyDynamics.behaviorVersion
        expectedStroke.brush.spacing = BrushSettings.legacyDynamics.spacing
        expectedStroke.brush.rotation = BrushSettings.legacyDynamics.rotation
        expectedStroke.brush.bristleStrength = BrushSettings.legacyDynamics.bristleStrength
        expectedStroke.brush.textureStrength = BrushSettings.legacyDynamics.textureStrength
        let expected = PaintingProject(
            schemaVersion: 3,
            canvas: legacy.canvas,
            paper: legacy.paper,
            layers: legacy.layers,
            commands: [.stroke(expectedStroke)]
        )
        let migratedRenderer = try WatercolorRenderer(project: reopened, device: device)
        let expectedRenderer = try WatercolorRenderer(project: expected, device: device)

        #expect(reopened == expected)
        #expect(try migratedRenderer.compositeChecksum() == expectedRenderer.compositeChecksum())
    }

    @Test func versionTwoPayloadWithoutDynamicsPreservesRenderingAcrossMigrationAndReopen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = UUID(uuidString: "6DCB29A6-F30B-4A8D-A4AE-F8C14A15687C")!
        let strokeID = UUID(uuidString: "D320F90A-3213-45D7-8DBF-8312B1DD687E")!
        let layer = PaintLayer(id: layerID, name: "Version 2 paint")
        let expectedBrush = BrushSettings(
            shape: .flat,
            hair: .bristle,
            texture: .mottled,
            style: .glazing,
            color: PaintColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 0.9),
            size: 24,
            opacity: 0.8,
            flow: 0.7,
            water: 0.6,
            granulation: 0.4,
            edgeBloom: 0.2,
            behaviorVersion: 0,
            spacing: 0.18,
            rotation: 0,
            bristleStrength: 0.5,
            textureStrength: 0.5
        )
        let expected = PaintingProject(
            schemaVersion: 3,
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [layer],
            commands: [.stroke(StrokeCommand(
                id: strokeID,
                layerID: layerID,
                tool: .brush,
                brush: expectedBrush,
                points: [
                    StrokePoint(x: 96, y: 120, pressure: 0.8, tiltX: 0, tiltY: 0, time: 0),
                    StrokePoint(x: 160, y: 120, pressure: 0.9, tiltX: 0, tiltY: 0, time: 1)
                ]
            ))]
        )

        let migrated = try PaintingDocumentCodec.decode(versionTwoPayloadWithoutDynamics())
        let expectedRenderer = try WatercolorRenderer(project: expected, device: device)
        let expectedChecksum = try expectedRenderer.compositeChecksum()
        let migratedRenderer = try WatercolorRenderer(project: migrated, device: device)

        #expect(migrated == expected)
        #expect(try migratedRenderer.compositeChecksum() == expectedChecksum)

        let reopened = try PaintingDocumentCodec.decode(PaintingDocumentCodec.encode(migrated))
        let reopenedRenderer = try WatercolorRenderer(project: reopened, device: device)

        #expect(reopened == expected)
        #expect(try reopenedRenderer.compositeChecksum() == expectedChecksum)
    }

    @Test func replayDuplicatesPigmentAndWetnessThenLetsLayersDiverge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(
            id: UUID(uuidString: "C3A83C61-78CF-424E-BE87-B1F06BBEC732")!,
            name: "Source"
        )
        let destination = PaintLayer(
            id: UUID(uuidString: "B20C2C0C-A93B-4777-A98E-F82D82979C5E")!,
            name: "Destination"
        )
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [source, destination]
        )
        project.commands = [
            .stroke(.testDot(
                id: UUID(uuidString: "41A630AF-42F0-4905-A7D5-14E48A39F493")!,
                layerID: source.id,
                color: PaintColor(red: 1, green: 0, blue: 0),
                x: 20,
                y: 32
            )),
            .duplicateLayer(DuplicateLayerCommand(
                sourceLayerID: source.id,
                destinationLayerID: destination.id
            )),
            .stroke(.testDot(
                id: UUID(uuidString: "D2D9CB17-4C8D-4D8A-9C29-7A6C8CF6A8EF")!,
                layerID: source.id,
                color: PaintColor(red: 0, green: 0, blue: 1),
                x: 44,
                y: 32
            ))
        ]

        let renderer = try WatercolorRenderer(project: project, device: device)

        let sourceCopyPoint = try renderer.debugPixel(x: 20, y: 32, layerID: source.id)
        let destinationCopyPoint = try renderer.debugPixel(x: 20, y: 32, layerID: destination.id)
        #expect(sourceCopyPoint.red > 0.1)
        #expect(destinationCopyPoint.red > 0.1)
        #expect(try renderer.debugWetness(x: 20, y: 32, layerID: destination.id) > 0.01)
        #expect(try renderer.debugPixel(x: 44, y: 32, layerID: source.id).blue > 0.1)
        #expect(try renderer.debugPixel(x: 44, y: 32, layerID: destination.id).blue == 0)
    }

    @Test func encodedDuplicateProjectReplaysIdenticallyAfterDecode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(name: "Source")
        let destination = PaintLayer(name: "Destination")
        var project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [source, destination]
        )
        project.commands = [
            .stroke(.testDot(layerID: source.id, x: 128, y: 128)),
            .duplicateLayer(DuplicateLayerCommand(
                sourceLayerID: source.id,
                destinationLayerID: destination.id
            ))
        ]
        let originalRenderer = try WatercolorRenderer(project: project, device: device)

        let data = try PaintingDocumentCodec.encode(project)
        let decoded = try PaintingDocumentCodec.decode(data)
        let decodedRenderer = try WatercolorRenderer(project: decoded, device: device)

        #expect(decoded == project)
        #expect(try decodedRenderer.compositeChecksum() == originalRenderer.compositeChecksum())
        #expect(
            try decodedRenderer.debugWetness(x: 128, y: 128, layerID: destination.id)
                == originalRenderer.debugWetness(x: 128, y: 128, layerID: destination.id)
        )
    }

    @Test func replayReusesSlicesForSequentialHistoricalLayers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: base, device: device)
        let destination = PaintLayer(name: "Surviving layer")
        let historicalLayerIDs = (0..<13).map { _ in UUID() }
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination]
        )
        project.commands = historicalLayerIDs.flatMap { sourceID in
            [
                .stroke(.testDot(
                    layerID: sourceID,
                    color: PaintColor(red: 1, green: 0, blue: 0)
                )),
                .mergeDown(MergeDownCommand(
                    sourceLayerID: sourceID,
                    destinationLayerID: destination.id
                ))
            ]
        }

        try renderer.replay(project: project)

        let merged = try renderer.debugPixel(x: 32, y: 32, layerID: destination.id)
        #expect(merged.red > 0.1)
        #expect(merged.alpha > 0.1)
        #expect(renderer.debugResources.pigmentArrayLength == 2)
    }

    @Test func replayReleasesDuplicateSourcesAfterTheirLastRelevantUse() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = PaintLayer(name: "Generation 0")
        let originalStroke = StrokeCommand.testDot(layerID: firstLayer.id, x: 32, y: 32)
        let original = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [firstLayer],
            commands: [.stroke(originalStroke)]
        )
        let expectedRenderer = try WatercolorRenderer(project: original, device: device)
        let expectedPixel = try expectedRenderer.debugPixel(x: 32, y: 32)
        let expectedWetness = try expectedRenderer.debugWetness(x: 32, y: 32)
        var editor = ProjectEditor(project: original)

        for generation in 1...16 {
            let sourceID = try #require(editor.project.layers.first?.id)
            try editor.duplicateLayer(id: sourceID, named: "Generation \(generation)")
            try editor.removeLayer(id: sourceID)
        }

        let renderer = try WatercolorRenderer(project: editor.project, device: device)
        let currentLayerID = try #require(editor.project.layers.first?.id)

        #expect(editor.project.layers.count == 1)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: currentLayerID) == expectedPixel)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: currentLayerID) == expectedWetness)
    }

    @Test func aReusedHistoricalSliceStartsBlankAfterDuplicateSourceRelease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(name: "Source")
        let destination = PaintLayer(name: "Destination")
        let laterHistorical = PaintLayer(name: "Later historical")
        let sourceStroke = StrokeCommand.testDot(
            layerID: source.id,
            color: PaintColor(red: 1, green: 0, blue: 0),
            x: 20,
            y: 32
        )
        let laterStroke = StrokeCommand.testDot(
            layerID: laterHistorical.id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            x: 44,
            y: 32
        )
        let duplicate = PaintingCommand.duplicateLayer(DuplicateLayerCommand(
            sourceLayerID: source.id,
            destinationLayerID: destination.id
        ))
        let merge = PaintingCommand.mergeDown(MergeDownCommand(
            sourceLayerID: laterHistorical.id,
            destinationLayerID: destination.id
        ))
        let base = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination],
            commands: [.stroke(sourceStroke), duplicate, .stroke(laterStroke), merge]
        )
        var explicitlyCleared = base
        explicitlyCleared.commands.insert(
            .clearLayer(LayerCommand(layerID: laterHistorical.id)),
            at: 2
        )

        let renderer = try WatercolorRenderer(project: base, device: device)
        let expectedRenderer = try WatercolorRenderer(project: explicitlyCleared, device: device)

        #expect(try renderer.compositeChecksum() == expectedRenderer.compositeChecksum())
        #expect(
            try renderer.debugWetness(x: 20, y: 32, layerID: destination.id)
                == expectedRenderer.debugWetness(x: 20, y: 32, layerID: destination.id)
        )
    }

    @Test func rejectedReplayLeavesPreviousProjectAndImageUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: original, device: device)
        try renderer.render(stroke: .testDot(
            layerID: original.layers[0].id,
            color: PaintColor(red: 1, green: 0, blue: 0)
        ))
        let projectBefore = renderer.project
        let checksumBefore = try renderer.compositeChecksum()
        let pigmentBefore = try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id)
        let destination = PaintLayer(name: "Destination")
        let simultaneousSourceIDs = (0..<13).map { _ in UUID() }
        var rejected = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [destination]
        )
        rejected.commands = simultaneousSourceIDs.map { sourceID in
            .stroke(.testDot(layerID: sourceID))
        } + simultaneousSourceIDs.map { sourceID in
            .mergeDown(MergeDownCommand(
                sourceLayerID: sourceID,
                destinationLayerID: destination.id
            ))
        }

        #expect(throws: RendererError.self) {
            try renderer.replay(project: rejected)
        }

        #expect(renderer.project == projectBefore)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id) == pigmentBefore)
        try renderer.render(stroke: .testDot(
            layerID: original.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1)
        ))
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id).blue > 0.1)
    }

    @Test func pressureControlsDepositAndDryingEvaporatesWetness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        try renderer.render(stroke: .testDot(layerID: layerID, pressure: 0.25))
        let lightDeposit = try renderer.debugPixel(x: 32, y: 32).alpha
        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID, pressure: 1))
        let heavyDeposit = try renderer.debugPixel(x: 32, y: 32).alpha
        let wetBefore = try renderer.debugWetness(x: 32, y: 32)
        try renderer.dry(layerID: layerID, steps: 8)

        #expect(heavyDeposit > lightDeposit)
        #expect(try renderer.debugWetness(x: 32, y: 32) < wetBefore)
    }

    @Test func canvasWetnessTracksRealRenderingReplayAndDrying() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        #expect(renderer.canvasWetness == 0)

        try renderer.renderAndWait(stroke: .testDot(layerID: layerID, tool: .water))
        let wetAfterStroke = renderer.canvasWetness
        #expect(wetAfterStroke > 0.1)

        try renderer.dry(layerID: layerID, steps: 24)
        #expect(renderer.canvasWetness < wetAfterStroke)

        try renderer.replay(project: project)
        #expect(renderer.canvasWetness == 0)
    }

    @Test func stagedWetnessReductionIsAccurateBoundedAndReusesItsBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        let project = PaintingProject(
            canvas: CanvasSize(width: 257, height: 259),
            paper: .coldPress,
            layers: [bottom, top]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugWetnessReductionResources

        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "00EB6EE7-13DD-4786-96AF-42796C94C70F")!,
            layerID: bottom.id,
            tool: .water,
            x: 16,
            y: 16
        ))
        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "DAB2E1AF-954F-4365-AC9C-8B52F0A48D3E")!,
            layerID: top.id,
            tool: .water,
            x: 256,
            y: 258
        ))

        let expectedMaximum = try renderer.debugMaximumWetness()
        #expect(abs(renderer.canvasWetness - expectedMaximum) < 0.000_01)
        #expect(renderer.debugWetnessReductionResources == resourcesBefore)
        #expect(resourcesBefore.finalStageThreadgroupCount == 1)
        #expect(
            resourcesBefore.firstStageThreadgroupCount
                < (project.canvas.width * project.canvas.height * PaintingProject.maximumLayerCount) / 32
        )

        try renderer.dry(layerID: bottom.id, steps: 8)
        try renderer.dry(layerID: top.id, steps: 8)
        #expect(renderer.debugWetnessReductionResources == resourcesBefore)
    }

    private func transformedSignature(
        tool: PaintTool,
        project: PaintingProject,
        renderer: WatercolorRenderer
    ) throws -> Int {
        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, x: 28, y: 32))
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: tool, x: 36, y: 32))
        return Int((try renderer.debugPixel(x: 38, y: 32).alpha * 100_000).rounded())
    }

    private func canonicalPhenotypeFixtures() -> [CanonicalPhenotypeFixture] {
        func point(
            _ x: Double,
            _ y: Double,
            _ index: Int,
            tiltX: Double = 0,
            tiltY: Double = 0
        ) -> StrokePoint {
            StrokePoint(
                x: x,
                y: y,
                pressure: 0.85,
                tiltX: tiltX,
                tiltY: tiltY,
                time: Double(index) * 0.1
            )
        }

        let horizontalCoordinates = [20.0, 30, 40, 50, 60, 70, 76]
        let verticalCoordinates = [20.0, 30, 40, 50, 60, 70, 76]
        let curvedCoordinates = [
            (20.0, 64.0),
            (28, 54),
            (38, 46),
            (50, 42),
            (62, 44),
            (72, 52),
            (78, 64)
        ]
        return [
            CanonicalPhenotypeFixture(
                name: "horizontal",
                strokeID: UUID(uuidString: "D15CB94A-F492-4808-822D-4696771FD2CD")!,
                points: horizontalCoordinates.enumerated().map {
                    point($0.element, 48, $0.offset)
                }
            ),
            CanonicalPhenotypeFixture(
                name: "vertical",
                strokeID: UUID(uuidString: "183750DB-545E-42F3-9048-02894C34D675")!,
                points: verticalCoordinates.enumerated().map {
                    point(48, $0.element, $0.offset)
                }
            ),
            CanonicalPhenotypeFixture(
                name: "curved",
                strokeID: UUID(uuidString: "9E007381-1E12-470F-BEE3-731FD3FEEB80")!,
                points: curvedCoordinates.enumerated().map {
                    point($0.element.0, $0.element.1, $0.offset)
                }
            ),
            CanonicalPhenotypeFixture(
                name: "tilted",
                strokeID: UUID(uuidString: "9D418AA5-AD61-4D2C-8B91-7D8295410747")!,
                points: horizontalCoordinates.enumerated().map {
                    point($0.element, 48, $0.offset, tiltX: 0.65, tiltY: -0.45)
                }
            )
        ]
    }

    private func renderPhenotypeMetrics(
        _ fixture: CanonicalPhenotypeFixture,
        device: MTLDevice
    ) throws -> BrushPhenotypeMetrics {
        let project = PaintingProject.testCanvas(96, paper: .coldPress)
        var brush = BrushSettings.default
        brush.shape = .flat
        brush.hair = .bristle
        brush.texture = .granulating
        brush.style = .wetOnWet
        brush.color = PaintColor(red: 0.72, green: 0.18, blue: 0.08, alpha: 0.9)
        brush.size = 18
        brush.opacity = 0.78
        brush.flow = 0.74
        brush.water = 0.82
        brush.granulation = 0.58
        brush.edgeBloom = 0.42
        let stroke = StrokeCommand(
            id: fixture.strokeID,
            layerID: project.layers[0].id,
            tool: .brush,
            brush: brush,
            points: fixture.points
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        try renderer.renderAndWait(stroke: stroke)
        return BrushPhenotypeMetrics.measure(
            try renderer.debugLayerFields(layerID: project.layers[0].id)
        )
    }

    private func phenotypeMetricScalars(_ metrics: BrushPhenotypeMetrics) -> [Double] {
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

    private func expectStablePhenotypeMetrics(
        _ first: BrushPhenotypeMetrics,
        _ second: BrushPhenotypeMetrics,
        fixtureName: String
    ) {
        let firstScalars = phenotypeMetricScalars(first)
        let secondScalars = phenotypeMetricScalars(second)
        for (lhs, rhs) in zip(firstScalars, secondScalars) {
            let tolerance = 0.000_000_01 + max(abs(lhs), abs(rhs)) * 0.000_001
            #expect(abs(lhs - rhs) <= tolerance, "\(fixtureName) metric changed between identical renders")
        }
        #expect(first.laneCount == second.laneCount)
    }

    private func phenotypeDiagnostics(_ metrics: BrushPhenotypeMetrics) -> String {
        "area=\(metrics.area), aspectRatio=\(metrics.aspectRatio), orientation=\(metrics.orientation), "
            + "edgeRoughness=\(metrics.edgeRoughness), voidRatio=\(metrics.voidRatio), "
            + "laneCount=\(metrics.laneCount), pigmentMass=\(metrics.pigmentMass), "
            + "wetnessMass=\(metrics.wetnessMass), spreadRadius=\(metrics.spreadRadius), "
            + "edgeConcentration=\(metrics.edgeConcentration)"
    }

    private func depositSignature(
        project: PaintingProject,
        renderer: WatercolorRenderer,
        configure: (inout BrushSettings) -> Void
    ) throws -> Int {
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        configure(&stroke.brush)
        var replay = project
        replay.commands = [.stroke(stroke)]
        try renderer.replay(project: replay)
        let center = try renderer.debugPixel(x: 32, y: 32).alpha
        let horizontal = try renderer.debugPixel(x: 38, y: 32).alpha
        let vertical = try renderer.debugPixel(x: 32, y: 38).alpha
        return Int(((center + horizontal * 1.7 + vertical * 2.3) * 100_000).rounded())
    }

    private func mergeFixture(sourceIsVisible: Bool, sourceOpacity: Double) -> PaintingProject {
        let destination = PaintLayer(
            id: UUID(uuidString: "86C089A3-CFFA-44F9-B7F0-57FE68572C25")!,
            name: "Destination"
        )
        let sourceID = UUID(uuidString: "18B8DA86-0C8A-4E98-B7E5-232434CB3839")!
        return PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination],
            commands: [
                .stroke(.testDot(
                    id: UUID(uuidString: "27D0DFCA-B8A3-4BAD-9DDE-AF14E3E49DC1")!,
                    layerID: destination.id,
                    color: PaintColor(red: 0, green: 0, blue: 1)
                )),
                .stroke(.testDot(
                    id: UUID(uuidString: "8E6C9734-3B1E-4B9E-B930-65EF80A91E4C")!,
                    layerID: sourceID,
                    color: PaintColor(red: 1, green: 0, blue: 0)
                )),
                .mergeDown(MergeDownCommand(
                    id: UUID(uuidString: "CA80E47B-AC50-48FC-9AE3-CB0F54D88F57")!,
                    sourceLayerID: sourceID,
                    destinationLayerID: destination.id,
                    sourceIsVisible: sourceIsVisible,
                    sourceOpacity: sourceOpacity
                ))
            ]
        )
    }
}

private struct CanonicalPhenotypeFixture {
    let name: String
    let strokeID: UUID
    let points: [StrokePoint]
}

private actor RendererPreviewCallSuspension {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RendererPreviewUpdateGate {
    private var shouldSuspend = true
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendOnce() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RendererPreviewCommandBufferMilestone {
    private var reference: RendererPreviewCommandBufferReference?
    private var waiters: [
        CheckedContinuation<RendererPreviewCommandBufferReference, Never>
    ] = []

    func record(_ commandBuffer: MTLCommandBuffer) {
        guard reference == nil else { return }
        let reference = RendererPreviewCommandBufferReference(commandBuffer: commandBuffer)
        self.reference = reference
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume(returning: reference) }
    }

    func waitForCommandBuffer() async -> RendererPreviewCommandBufferReference {
        if let reference { return reference }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct RendererPreviewCommandBufferReference: @unchecked Sendable {
    let commandBuffer: MTLCommandBuffer
}

@MainActor
private final class RendererPreviewMilestone {
    private var wasRecorded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        guard !wasRecorded else { return }
        wasRecorded = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilRecorded() async {
        guard !wasRecorded else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func versionTwoPayloadWithoutDynamics() throws -> Data {
    let object: [String: Any] = [
        "schemaVersion": 2,
        "canvas": ["width": 256, "height": 256],
        "paper": "rough",
        "layers": [[
            "id": "6DCB29A6-F30B-4A8D-A4AE-F8C14A15687C",
            "name": "Version 2 paint",
            "isVisible": true,
            "opacity": 1.0
        ]],
        "commands": [[
            "stroke": [
                "_0": [
                    "id": "D320F90A-3213-45D7-8DBF-8312B1DD687E",
                    "layerID": "6DCB29A6-F30B-4A8D-A4AE-F8C14A15687C",
                    "tool": "brush",
                    "brush": [
                        "shape": "flat",
                        "hair": "bristle",
                        "texture": "mottled",
                        "style": "glazing",
                        "color": ["red": 0.5, "green": 0.25, "blue": 0.75, "alpha": 0.9],
                        "size": 24.0,
                        "opacity": 0.8,
                        "flow": 0.7,
                        "water": 0.6,
                        "granulation": 0.4,
                        "edgeBloom": 0.2
                    ],
                    "points": [
                        ["x": 96.0, "y": 120.0, "pressure": 0.8, "tiltX": 0.0, "tiltY": 0.0, "time": 0.0],
                        ["x": 160.0, "y": 120.0, "pressure": 0.9, "tiltX": 0.0, "tiltY": 0.0, "time": 1.0]
                    ]
                ]
            ]
        ]]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private extension PaintingProject {
    static func testCanvas(_ side: Int, paper: PaperTexture = .coldPress) -> Self {
        Self(
            canvas: CanvasSize(width: side, height: side),
            paper: paper,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "1F34CEB5-F10B-4AEC-937F-E33603DDCBA2")!,
                    name: "Paint"
                )
            ]
        )
    }
}

private extension StrokeCommand {
    static func testDot(
        id: UUID = UUID(),
        layerID: UUID,
        tool: PaintTool = .brush,
        pressure: Double = 1,
        color: PaintColor = PaintColor(red: 0.8, green: 0.2, blue: 0.1),
        x: Double = 32,
        y: Double = 32
    ) -> Self {
        Self(
            id: id,
            layerID: layerID,
            tool: tool,
            brush: BrushSettings(
                shape: .round,
                hair: .sable,
                texture: .smooth,
                style: .transparentWash,
                color: color,
                size: 20,
                opacity: 0.8,
                flow: 0.8,
                water: 0.6,
                granulation: 0.2,
                edgeBloom: 0.15
            ),
            points: [StrokePoint(x: x, y: y, pressure: pressure, tiltX: 1, tiltY: 0, time: 0)]
        )
    }

    static func testLine(
        id: UUID = UUID(),
        layerID: UUID,
        color: PaintColor,
        y: Double,
        water: Double
    ) -> Self {
        var brush = testDot(layerID: layerID).brush
        brush.color = color
        brush.water = water
        return Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: stride(from: 8.0, through: 56.0, by: 4.0).map {
                StrokePoint(x: $0, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: $0)
            }
        )
    }
}

private extension WatercolorRenderer {
    func compositeChecksum() throws -> UInt64 {
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

    func compositePixel(x: Int, y: Int) throws -> PaintColor {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The test could not access image bytes")
        }
        let offset = y * image.bytesPerRow + x * 4
        return PaintColor(
            red: Double(bytes[offset + 2]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset]) / 255,
            alpha: Double(bytes[offset + 3]) / 255
        )
    }
}
