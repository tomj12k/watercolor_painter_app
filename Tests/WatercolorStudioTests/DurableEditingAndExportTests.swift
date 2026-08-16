import Foundation
import ImageIO
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite @MainActor struct DurableEditingAndExportTests {
    @Test func undoAndRedoReplayStrokePixelsAndPublishEachProjectOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let renderer = try WatercolorRenderer(project: project, device: device)
        let blankChecksum = try renderer.pixelChecksum()
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let stroke = StrokeCommand.durableFixture(layerID: project.layers[0].id)
        model.completeStroke(stroke)
        let paintedProject = model.project
        let paintedChecksum = try model.rendererForTesting.pixelChecksum()

        model.undo()

        #expect(model.project == project)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == project)
        #expect(try model.rendererForTesting.pixelChecksum() == blankChecksum)
        #expect(!model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)

        model.redo()

        #expect(model.project == paintedProject)
        #expect(model.selectedLayerID == project.layers[0].id)
        #expect(model.rendererProject == paintedProject)
        #expect(try model.rendererForTesting.pixelChecksum() == paintedChecksum)
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project, paintedProject])
    }

    @Test func persistentUndoAndRedoReplayFailurePreservesLiveStateAndHistory() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let injectedError = NSError(
            domain: "DurableEditingAndExportTests",
            code: 31,
            userInfo: [NSLocalizedDescriptionKey: "persistent undo replay failure"]
        )
        var shouldFailReplay = false
        var failedReplayCount = 0
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailReplay, commandBuffer.label == "Watercolor replay" {
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
        model.completeStroke(.durableFixture(layerID: project.layers[0].id))
        let paintedProject = model.project
        let paintedRendererIdentity = model.rendererIdentity
        let paintedChecksum = try renderer.pixelChecksum()
        shouldFailReplay = true

        model.undo()
        model.undo()

        #expect(model.project == paintedProject)
        #expect(model.rendererProject == paintedProject)
        #expect(model.rendererIdentity == paintedRendererIdentity)
        #expect(try renderer.pixelChecksum() == paintedChecksum)
        #expect(model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject])
        #expect(failedReplayCount == 2)
        #expect(model.error?.code == .gpuExecution)

        shouldFailReplay = false
        model.undo()

        #expect(model.project == project)
        #expect(model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project])

        let undoneRendererIdentity = model.rendererIdentity
        let undoneChecksum = try model.rendererForTesting.pixelChecksum()
        shouldFailReplay = true
        model.redo()
        model.redo()

        #expect(model.project == project)
        #expect(model.rendererProject == project)
        #expect(model.rendererIdentity == undoneRendererIdentity)
        #expect(try model.rendererForTesting.pixelChecksum() == undoneChecksum)
        #expect(!model.capabilities.canUndo)
        #expect(model.capabilities.canRedo)
        #expect(documentUpdates == [paintedProject, project])
        #expect(failedReplayCount == 4)

        shouldFailReplay = false
        model.redo()
        #expect(model.project == paintedProject)
        #expect(documentUpdates == [paintedProject, project, paintedProject])
    }

    @Test func drySelectedLayerAppendsOneFixedCommandAndDecreasesLiveWetness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.durableFixture()
        var wetStroke = StrokeCommand.durableFixture(layerID: project.layers[0].id)
        wetStroke.tool = .water
        project.commands = [.stroke(wetStroke)]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let wetnessBefore = renderer.canvasWetness
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )

        model.drySelectedLayer()

        #expect(model.project.commands.count == 2)
        guard case let .dryLayer(command) = model.project.commands.last else {
            Issue.record("Expected one durable dry-layer command")
            return
        }
        #expect(command.layerID == project.layers[0].id)
        #expect(command.steps == 24)
        #expect(model.canvasWetness < wetnessBefore)
        #expect(model.canvasWetness == model.rendererForTesting.canvasWetness)
        #expect(documentUpdates == [model.project])
    }

    @Test func mergeCommandSurvivesUndoRedoSaveAndReopen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.durableFixture(layerID: bottom.id, x: 112)),
            .stroke(.durableFixture(layerID: top.id, x: 144))
        ]
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        model.selectedLayerID = top.id

        model.mergeSelectedLayerDown()
        let mergedProject = model.project
        let mergedChecksum = try model.rendererForTesting.pixelChecksum()
        guard case let .mergeDown(merge) = mergedProject.commands.last else {
            Issue.record("Expected a semantic merge command")
            return
        }
        #expect(merge.sourceLayerID == top.id)
        #expect(merge.destinationLayerID == bottom.id)

        model.undo()
        #expect(model.project == project)
        #expect(project.layers.contains(where: { $0.id == model.selectedLayerID }))

        model.redo()
        #expect(model.project == mergedProject)
        #expect(model.selectedLayerID == bottom.id)
        #expect(try model.rendererForTesting.pixelChecksum() == mergedChecksum)

        let reopened = try PaintingDocumentCodec.decode(PaintingDocumentCodec.encode(mergedProject))
        let reopenedRenderer = try WatercolorRenderer(project: reopened, device: device)
        #expect(reopened == mergedProject)
        #expect(try reopenedRenderer.pixelChecksum() == mergedChecksum)
    }

    @Test func pngExportWritesFinalCanvasWithoutMutatingTheProjectOrHistory() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.durableFixture()
        project.commands = [.stroke(.durableFixture(layerID: project.layers[0].id))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        var documentUpdates: [PaintingProject] = []
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let rendererIdentity = model.rendererIdentity
        let wetness = model.canvasWetness
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("final.png")

        await model.exportPNG(to: destination)

        let data = try Data(contentsOf: destination)
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == project.canvas.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == project.canvas.height)
        #expect(model.project == project)
        #expect(model.rendererIdentity == rendererIdentity)
        #expect(model.canvasWetness == wetness)
        #expect(!model.capabilities.canUndo)
        #expect(!model.capabilities.canRedo)
        #expect(documentUpdates.isEmpty)
        #expect(model.error == nil)
    }

    @Test func failedPNGExportPreservesAnExistingDestinationAndReportsFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: directory.path
        )

        await model.exportPNG(to: destination)

        #expect(try Data(contentsOf: destination) == original)
        #expect(model.project == project)
        #expect(model.error?.code == .export)
        #expect(model.error?.recoverySuggestion.contains("writable location") == true)
        #expect(model.error?.diagnostic.customerText.contains("existing.png") == false)
        #expect(model.error?.id != nil)
    }

    @Test func newerSameDestinationExportCannotBeOverwrittenByOlderWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = SequencedDestinationExports()
        let olderModel = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try await exports.run(to: temporaryURL)
            }
        )
        let newerModel = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try await exports.run(to: temporaryURL)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("shared.png")
        let aliasDirectory = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let aliasedDestination = aliasDirectory.appendingPathComponent("../shared.png")

        let older = Task { @MainActor in await olderModel.exportPNG(to: aliasedDestination) }
        await exports.waitUntilStarted(1)
        let newer = Task { @MainActor in await newerModel.exportPNG(to: destination) }
        await exports.waitUntilStarted(2)

        await exports.complete(2)
        await newer.value
        #expect(try Data(contentsOf: destination) == Data("request-2".utf8))

        await exports.complete(1)
        await older.value
        #expect(try Data(contentsOf: destination) == Data("request-2".utf8))
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!remainingNames.contains(where: { $0.contains("watercolor-export") }))
    }

    @Test func latestExportAtomicallyReplacesAnExistingDestination() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let replacement = Data("replacement export".utf8)
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try replacement.write(to: temporaryURL, options: .atomic)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        try Data("old export".utf8).write(to: destination)

        await model.exportPNG(to: destination)

        #expect(try Data(contentsOf: destination) == replacement)
        #expect(model.error == nil)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remainingNames == [destination.lastPathComponent])
    }

    @Test func newerFailedRequestStillPreventsOlderWorkFromReplacingTheDestination() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = SequencedDestinationExports()
        let olderModel = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try await exports.run(to: temporaryURL)
            }
        )
        let newerModel = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try await exports.run(to: temporaryURL)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("shared.png")
        let original = Data("last completed export".utf8)
        try original.write(to: destination)

        let older = Task { @MainActor in await olderModel.exportPNG(to: destination) }
        await exports.waitUntilStarted(1)
        let newer = Task { @MainActor in await newerModel.exportPNG(to: destination) }
        await exports.waitUntilStarted(2)

        await exports.complete(2, with: .failure)
        await newer.value
        #expect(newerModel.error?.code == .export)

        await exports.complete(1)
        await older.value
        #expect(try Data(contentsOf: destination) == original)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remainingNames == [destination.lastPathComponent])
    }

    @Test func failedWorkerRemovesStagingAndPreservesAnExistingDestination() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let original = Data("existing export".utf8)
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try Data("incomplete export".utf8).write(to: temporaryURL, options: .atomic)
                throw ControlledExportError(message: "injected worker failure")
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        try original.write(to: destination)

        await model.exportPNG(to: destination)

        #expect(try Data(contentsOf: destination) == original)
        #expect(model.error?.code == .export)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remainingNames == [destination.lastPathComponent])
    }

    @Test func differentDestinationExportsDoNotBlockEachOther() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = SequencedDestinationExports()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, _ in
                try await exports.run(to: temporaryURL)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDestination = directory.appendingPathComponent("first.png")
        let secondDestination = directory.appendingPathComponent("second.png")

        let first = Task { @MainActor in await model.exportPNG(to: firstDestination) }
        await exports.waitUntilStarted(1)
        let second = Task { @MainActor in await model.exportPNG(to: secondDestination) }
        await exports.waitUntilStarted(2)

        await exports.complete(2)
        await second.value
        #expect(try Data(contentsOf: secondDestination) == Data("request-2".utf8))

        await exports.complete(1)
        await first.value
        #expect(try Data(contentsOf: firstDestination) == Data("request-1".utf8))
    }

    @Test func blockedPNGEncodingLeavesTheMainActorSchedulable() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let blockingGate = BlockingExportGate()
        let worker = StudioPNGExportWorker { _, temporaryURL, _ in
            blockingGate.block()
            try Data("completed export".utf8).write(to: temporaryURL, options: .atomic)
        }
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: worker
        )

        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            blockingGate.failSafeRelease()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = Task { @MainActor in
            await model.exportPNG(to: directory.appendingPathComponent("blocked-export.png"))
        }
        let startResult = await Task.detached {
            blockingGate.waitUntilBlocked()
        }.value
        #expect(startResult == .blocked)

        let mainActorRanWhileBlocked = await Task { @MainActor in
            let isBlocked = blockingGate.isBlocked
            blockingGate.release()
            return isBlocked
        }.value

        #expect(mainActorRanWhileBlocked)
        await export.value
        #expect(blockingGate.wasReleasedByMainActor)
    }

    @Test func exportGateFailSafeWakesWaiterBeforeWorkerStarts() async {
        let blockingGate = BlockingExportGate()
        let waiter = Task.detached {
            blockingGate.waitUntilBlocked()
        }

        blockingGate.failSafeRelease()

        #expect(await waiter.value == .failSafe)
    }

    @Test func olderExportSuccessDoesNotClearALaterActionFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = ControlledPNGExports()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, destinationURL in
                try await exports.run(destinationURL.lastPathComponent)
                try Data("controlled export".utf8).write(to: temporaryURL, options: .atomic)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("old-success.png")
        let export = Task { @MainActor in await model.exportPNG(to: destination) }
        await exports.waitUntilStarted("old-success.png")

        let missingLayerID = UUID(uuidString: "414CFB67-D2B5-45A4-B4CF-68149B67D49C")!
        model.completeStroke(.durableFixture(layerID: missingLayerID))
        let laterFailure = try #require(model.error)
        await exports.complete("old-success.png", with: .success)
        await export.value

        #expect(model.error == laterFailure)
        #expect(model.error?.message.contains(missingLayerID.uuidString) == false)
        #expect(model.error?.message.contains("selected layer") == true)
    }

    @Test func olderExportFailureDoesNotOverwriteALaterActionFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = ControlledPNGExports()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, destinationURL in
                try await exports.run(destinationURL.lastPathComponent)
                try Data("controlled export".utf8).write(to: temporaryURL, options: .atomic)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("old-failure.png")
        let export = Task { @MainActor in await model.exportPNG(to: destination) }
        await exports.waitUntilStarted("old-failure.png")

        let missingLayerID = UUID(uuidString: "40991B21-4D75-49D1-BE02-28023D6C950D")!
        model.completeStroke(.durableFixture(layerID: missingLayerID))
        let laterFailure = try #require(model.error)
        await exports.complete("old-failure.png", with: .failure("stale export failure"))
        await export.value

        #expect(model.error == laterFailure)
        #expect(model.error?.message.contains("stale export failure") == false)
    }

    @Test func olderExportSuccessDoesNotClearTheNewestExportFailure() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = ControlledPNGExports()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, destinationURL in
                try await exports.run(destinationURL.lastPathComponent)
                try Data("controlled export".utf8).write(to: temporaryURL, options: .atomic)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Task { @MainActor in
            await model.exportPNG(to: directory.appendingPathComponent("older-success.png"))
        }
        await exports.waitUntilStarted("older-success.png")
        let newest = Task { @MainActor in
            await model.exportPNG(to: directory.appendingPathComponent("newest-failure.png"))
        }
        await exports.waitUntilStarted("newest-failure.png")

        await exports.complete("newest-failure.png", with: .failure("newest export failure"))
        await newest.value
        let newestFailure = try #require(model.error)
        await exports.complete("older-success.png", with: .success)
        await older.value

        #expect(model.error == newestFailure)
        #expect(model.error?.code == .export)
        #expect(model.error?.diagnostic.customerText.contains("newest-failure.png") == false)
        #expect(model.error?.diagnostic.customerText.contains("newest export failure") == false)
    }

    @Test func olderExportFailureDoesNotOverwriteTheNewestExportSuccess() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.durableFixture()
        let exports = ControlledPNGExports()
        let model = StudioModel(
            project: project,
            renderer: try WatercolorRenderer(project: project, device: device),
            pngExportWorker: StudioPNGExportWorker { _, temporaryURL, destinationURL in
                try await exports.run(destinationURL.lastPathComponent)
                try Data("controlled export".utf8).write(to: temporaryURL, options: .atomic)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Task { @MainActor in
            await model.exportPNG(to: directory.appendingPathComponent("older-failure.png"))
        }
        await exports.waitUntilStarted("older-failure.png")
        let newest = Task { @MainActor in
            await model.exportPNG(to: directory.appendingPathComponent("newest-success.png"))
        }
        await exports.waitUntilStarted("newest-success.png")

        await exports.complete("newest-success.png", with: .success)
        await newest.value
        #expect(model.error == nil)
        await exports.complete("older-failure.png", with: .failure("older export failure"))
        await older.value

        #expect(model.error == nil)
    }
}

private final class BlockingExportGate: @unchecked Sendable {
    enum StartResult: Sendable {
        case blocked
        case failSafe
    }

    private enum ReleaseReason {
        case mainActor
        case failSafe
    }

    private let lock = NSLock()
    private let startResolved = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private var blocked = false
    private var startResult: StartResult?
    private var releaseReason: ReleaseReason?

    func block() {
        let state = lock.withLock {
            blocked = true
            guard releaseReason != .failSafe else {
                return (signalStart: false, shouldWait: false)
            }
            let signalStart = startResult == nil
            if signalStart {
                startResult = .blocked
            }
            return (signalStart: signalStart, shouldWait: true)
        }
        if state.signalStart {
            startResolved.signal()
        }
        if state.shouldWait {
            releaseGate.wait()
        }
        lock.withLock { blocked = false }
    }

    func waitUntilBlocked() -> StartResult {
        startResolved.wait()
        return lock.withLock {
            guard let startResult else {
                preconditionFailure("Start semaphore signaled without a result")
            }
            return startResult
        }
    }

    var isBlocked: Bool {
        lock.withLock { blocked }
    }

    func release() {
        release(reason: .mainActor)
    }

    func failSafeRelease() {
        let state = lock.withLock {
            guard releaseReason == nil else {
                return (signalStart: false, signalRelease: false)
            }
            releaseReason = .failSafe
            let signalStart = startResult == nil
            if signalStart {
                startResult = .failSafe
            }
            return (signalStart: signalStart, signalRelease: blocked)
        }
        if state.signalStart {
            startResolved.signal()
        }
        if state.signalRelease {
            releaseGate.signal()
        }
    }

    var wasReleasedByMainActor: Bool {
        lock.withLock { releaseReason == .mainActor }
    }

    private func release(reason: ReleaseReason) {
        let shouldSignal = lock.withLock {
            guard blocked, releaseReason == nil else { return false }
            releaseReason = reason
            return true
        }
        if shouldSignal {
            releaseGate.signal()
        }
    }
}

private actor ControlledPNGExports {
    enum Outcome: Sendable {
        case success
        case failure(String)
    }

    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var completionWaiters: [String: CheckedContinuation<Outcome, Never>] = [:]

    func run(_ name: String) async throws {
        started.insert(name)
        startWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
        let outcome = if let outcome = outcomes.removeValue(forKey: name) {
            outcome
        } else {
            await withCheckedContinuation { continuation in
                completionWaiters[name] = continuation
            }
        }
        if case let .failure(message) = outcome {
            throw ControlledExportError(message: message)
        }
    }

    func waitUntilStarted(_ name: String) async {
        guard !started.contains(name) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[name, default: []].append(continuation)
        }
    }

    func complete(_ name: String, with outcome: Outcome) {
        if let continuation = completionWaiters.removeValue(forKey: name) {
            continuation.resume(returning: outcome)
        } else {
            outcomes[name] = outcome
        }
    }
}

private actor SequencedDestinationExports {
    enum Outcome: Sendable {
        case success
        case failure
    }

    private var nextRequest = 0
    private var started: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Int: CheckedContinuation<Outcome, Never>] = [:]
    private var completed: [Int: Outcome] = [:]

    func run(to destinationURL: URL) async throws {
        nextRequest += 1
        let request = nextRequest
        started.insert(request)
        startWaiters.removeValue(forKey: request)?.forEach { $0.resume() }

        let outcome = if let completedOutcome = completed.removeValue(forKey: request) {
            completedOutcome
        } else {
            await withCheckedContinuation { continuation in
                completionWaiters[request] = continuation
            }
        }

        if outcome == .failure {
            throw ControlledExportError(message: "injected request failure")
        }

        try Data("request-\(request)".utf8).write(to: destinationURL, options: .atomic)
    }

    func waitUntilStarted(_ request: Int) async {
        guard !started.contains(request) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[request, default: []].append(continuation)
        }
    }

    func complete(_ request: Int, with outcome: Outcome = .success) {
        if let continuation = completionWaiters.removeValue(forKey: request) {
            continuation.resume(returning: outcome)
        } else {
            completed[request] = outcome
        }
    }
}

private struct ControlledExportError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private extension PaintingProject {
    static func durableFixture() -> Self {
        Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "9CF9177D-247F-41FA-9529-165972589761")!,
                    name: "Layer 1"
                )
            ]
        )
    }
}

private extension StrokeCommand {
    static func durableFixture(
        id: UUID = UUID(),
        layerID: UUID,
        x: Double = 128,
        y: Double = 128
    ) -> Self {
        var brush = BrushSettings.default
        brush.color = PaintColor(red: 0.8, green: 0.2, blue: 0.1)
        brush.opacity = 0.8
        brush.flow = 0.8
        return Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: [StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}
