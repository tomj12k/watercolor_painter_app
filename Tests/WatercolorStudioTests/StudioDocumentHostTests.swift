import CoreGraphics
import Metal
import SwiftUI
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

@Suite @MainActor struct StudioDocumentHostTests {
    @Test func externalDocumentReplacementBecomesTheBaseForTheNextModelEdit() throws {
        let initialProject = PaintingProject.studioHostTestProject(layerName: "Initial")
        var replacementProject = PaintingProject.studioHostTestProject(layerName: "Replacement")
        replacementProject.paper = .rough
        let document = StudioDocumentBox(PaintingDocument(project: initialProject))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let host = StudioDocumentHost(document: binding)
        let model = try #require(host.model)

        document.value.project = replacementProject
        host.receiveDocumentProject(document.value.project)

        #expect(model.project == replacementProject)
        #expect(document.value.project == replacementProject)

        model.addLayer()

        #expect(model.project.layers.map(\.name) == ["Replacement", "Layer 2"])
        #expect(model.project.paper == .rough)
        #expect(document.value.project == model.project)
    }

    @Test func rendererFactoryFailureBecomesTheHostsIdentifiableFailure() {
        let project = PaintingProject.studioHostTestProject(layerName: "Initial")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let expected = NSError(
            domain: "StudioDocumentHostTests",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "renderer initialization failed"]
        )

        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { _, _ in throw expected }
        )

        #expect(host.model == nil)
        #expect(host.failure?.code == .metalUnavailable)
        #expect(host.failure?.message.contains("renderer initialization failed") == false)

        host.dismissFailure()
        #expect(host.failure == nil)
    }

    @Test func rendererInitializationRetryPreservesThenAttachesTheOriginalDocumentExactlyOnce() throws {
        let project = PaintingProject.studioHostTestProject(layerName: "Original")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        var attempts = 0
        var successfulModels = 0
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { project, update in
                attempts += 1
                if attempts == 1 {
                    throw RendererError.metalUnavailable
                }
                successfulModels += 1
                return try StudioModel(project: project, onDocumentUpdate: update)
            }
        )

        #expect(host.model == nil)
        #expect(host.failure?.code == .metalUnavailable)
        #expect(host.canRetryRendererInitialization)
        #expect(document.value.project == project)

        #expect(host.retryRendererInitialization())
        #expect(host.model?.project == project)
        #expect(document.value.project == project)
        #expect(host.failure == nil)
        #expect(attempts == 2)
        #expect(successfulModels == 1)

        #expect(!host.retryRendererInitialization())
        #expect(attempts == 2)
        #expect(successfulModels == 1)
    }

    @Test func failedDefaultRendererCanRecoverByCreatingASmallerCanvas() throws {
        let originalDocument = PaintingDocument()
        let originalProject = originalDocument.project
        let document = StudioDocumentBox(originalDocument)
        var documentWrites = 0
        let binding = Binding(
            get: { document.value },
            set: { (updatedDocument: PaintingDocument) in
                documentWrites += 1
                document.value = updatedDocument
            }
        )
        var attemptedCanvases: [CanvasSize] = []
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { project, update in
                attemptedCanvases.append(project.canvas)
                if project.canvas == originalProject.canvas {
                    throw RendererError.resourceBudgetExceeded(
                        required: 2_000_000_000,
                        available: 1_000_000_000
                    )
                }
                return try StudioModel(project: project, onDocumentUpdate: update)
            }
        )
        let smaller = NewCanvasConfiguration(width: 256, height: 320, paper: .hotPress)

        #expect(host.model == nil)
        #expect(host.failure?.code == .resourceBudget)
        #expect(document.value.project == originalProject)
        #expect(document.value.needsInitialConfiguration)

        #expect(host.configureNewDocument(smaller))
        #expect(attemptedCanvases == [originalProject.canvas, smaller.canvas])
        #expect(host.model?.project.canvas == smaller.canvas)
        #expect(document.value.project.canvas == smaller.canvas)
        #expect(!document.value.needsInitialConfiguration)
        #expect(documentWrites == 1)
        #expect(host.failure == nil)
    }

    @Test func hostAndModelReleaseAfterTheDocumentOwnerCloses() throws {
        let document = StudioDocumentBox(
            PaintingDocument(project: .studioHostTestProject(layerName: "Lifetime"))
        )
        let binding = Binding(
            get: { document.value },
            set: { (updatedDocument: PaintingDocument) in document.value = updatedDocument }
        )
        var host: StudioDocumentHost? = StudioDocumentHost(document: binding)
        weak let weakHost = host
        weak let weakModel = host?.model

        host = nil

        #expect(weakHost == nil)
        #expect(weakModel == nil)
    }

    @Test func allocationAndShaderInitializationFailuresUseStartRecoveryLanguage() {
        let project = PaintingProject.studioHostTestProject(layerName: "Initialization")

        for error in [
            RendererError.allocation("private texture name"),
            RendererError.shaderCompilation("private compiler output")
        ] {
            let failure = StudioFailure.rendererInitialization(error: error, project: project)

            #expect(failure.code == .gpuExecution)
            #expect(failure.message.contains("start the watercolor renderer"))
            #expect(failure.recoverySuggestion.contains("Try again"))
            #expect(!failure.message.contains("that change"))
            #expect(!failure.recoverySuggestion.contains("save and reopen"))
            #expect(!failure.message.contains("private"))
        }
    }

    @Test func copyDetailsWritesOnlyThePrivacySafeDiagnosticText() {
        let project = PaintingProject.studioHostTestProject(layerName: "Private Layer")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        var copiedText: String?
        let host = StudioDocumentHost(
            document: binding,
            diagnosticWriter: { copiedText = $0 }
        )
        let failure = StudioFailure(
            error: NSError(
                domain: "Sensitive",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "/Users/customer/Secret.watercolor"]
            ),
            project: project
        )

        host.copyDetails(for: failure)

        #expect(copiedText == failure.diagnostic.customerText)
        #expect(copiedText?.contains("Private Layer") == false)
        #expect(copiedText?.contains("/Users/customer") == false)
    }

    @Test func replacementReplayFailureFlowsThroughTheSameHostFailure() throws {
        let project = PaintingProject.studioHostTestProject(layerName: "Initial")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let host = StudioDocumentHost(document: binding)
        let model = try #require(host.model)
        var invalidReplacement = PaintingProject.studioHostTestProject(layerName: "Invalid")
        invalidReplacement.schemaVersion = PaintingProject.currentSchemaVersion + 1

        document.value.project = invalidReplacement
        host.receiveDocumentProject(invalidReplacement)

        #expect(model.project == project)
        #expect(host.failure?.message.isEmpty == false)

        host.dismissFailure()
        #expect(host.failure == nil)
        #expect(model.error == nil)
    }

    @Test func newCanvasAllocationFailureKeepsTheExistingDocumentAndConfigurationOpen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioHostTestProject(layerName: "Initial")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let expected = NSError(
            domain: "StudioDocumentHostTests",
            code: 23,
            userInfo: [NSLocalizedDescriptionKey: "canvas texture allocation failed"]
        )
        var shouldFail = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                shouldFail && commandBuffer.label == "Watercolor replay" ? expected : commandBuffer.error
            }
        )
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { project, update in
                StudioModel(project: project, renderer: renderer, onDocumentUpdate: update)
            }
        )
        shouldFail = true

        let configured = host.configureNewDocument(
            NewCanvasConfiguration(width: 256, height: 256, paper: .rough)
        )

        #expect(!configured)
        #expect(document.value.project == project)
        #expect(host.model?.project == project)
        #expect(host.failure?.code == .gpuExecution)
        #expect(host.failure?.message.contains("canvas texture allocation failed") == false)
    }

    @Test func retryingNewCanvasAfterResourceFailureReplacesTheDocumentExactlyOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.studioHostTestProject(layerName: "Original")
        var initialDocument = PaintingDocument(project: original)
        initialDocument.needsInitialConfiguration = true
        let document = StudioDocumentBox(initialDocument)
        var documentWrites = 0
        let binding = Binding(
            get: { document.value },
            set: { (updatedDocument: PaintingDocument) in
                documentWrites += 1
                document.value = updatedDocument
            }
        )
        let expected = NSError(
            domain: "StudioDocumentHostTests",
            code: 41,
            userInfo: [NSLocalizedDescriptionKey: "private allocation detail"]
        )
        var shouldFail = false
        let renderer = try WatercolorRenderer(
            project: original,
            device: device,
            debugCommandBufferError: { commandBuffer in
                shouldFail && commandBuffer.label == "Watercolor replay"
                    ? expected
                    : commandBuffer.error
            }
        )
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { project, update in
                StudioModel(project: project, renderer: renderer, onDocumentUpdate: update)
            }
        )
        let configuration = NewCanvasConfiguration(width: 256, height: 320, paper: .handmade)

        shouldFail = true
        #expect(!host.configureNewDocument(configuration))
        #expect(document.value.project == original)
        #expect(document.value.needsInitialConfiguration)
        #expect(documentWrites == 0)

        shouldFail = false
        #expect(host.configureNewDocument(configuration))
        #expect(document.value.project.canvas == configuration.canvas)
        #expect(document.value.project.paper == PaperTexture.handmade)
        #expect(!document.value.needsInitialConfiguration)
        #expect(documentWrites == 1)
        #expect(host.failure == nil)
    }

    @Test func useDefaultCompletesInitialConfigurationOnlyWhenTheRendererIsAvailable() {
        let document = StudioDocumentBox(PaintingDocument())
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let host = StudioDocumentHost(document: binding)

        let configured = host.useDefaultCanvas()

        #expect(configured)
        #expect(!document.value.needsInitialConfiguration)
        #expect(host.failure == nil)
    }

    @Test func useDefaultFailureKeepsInitialConfigurationActive() {
        let document = StudioDocumentBox(PaintingDocument())
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let expected = NSError(
            domain: "StudioDocumentHostTests",
            code: 29,
            userInfo: [NSLocalizedDescriptionKey: "default canvas allocation failed"]
        )
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { _, _ in throw expected }
        )

        let configured = host.useDefaultCanvas()

        #expect(!configured)
        #expect(document.value.needsInitialConfiguration)
        #expect(host.failure?.code == .metalUnavailable)
        #expect(host.failure?.message.contains("default canvas allocation failed") == false)
    }

    @Test func resourceRejectionKeepsTheExistingDocumentAndRendererUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.studioHostTestProject(layerName: "Initial")
        let document = StudioDocumentBox(PaintingDocument(project: project))
        let binding = Binding(
            get: { document.value },
            set: { document.value = $0 }
        )
        let policy = RendererResourcePolicy(maximumWorkingSetBytes: 30_000_000)
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugResourcePolicy: policy
        )
        let host = StudioDocumentHost(
            document: binding,
            modelFactory: { project, update in
                StudioModel(project: project, renderer: renderer, onDocumentUpdate: update)
            }
        )
        let model = try #require(host.model)
        let rendererIdentity = model.rendererIdentity
        let checksumBefore = try renderer.hostChecksum()

        let configured = host.configureNewDocument(
            NewCanvasConfiguration(width: 1_024, height: 1_024, paper: .rough)
        )

        #expect(!configured)
        #expect(document.value.project == project)
        #expect(model.project == project)
        #expect(model.rendererIdentity == rendererIdentity)
        #expect(try renderer.hostChecksum() == checksumBefore)
        #expect(host.failure?.code == .resourceBudget)
        #expect(
            host.failure?.recoverySuggestion.contains("Reduce the canvas size or layer count") == true
        )

        let stroke = StrokeCommand(
            layerID: project.layers[0].id,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 32, y: 32, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
        model.completeStroke(stroke)

        #expect(model.project.commands == [.stroke(stroke)])
        #expect(document.value.project == model.project)
        #expect(model.rendererIdentity == rendererIdentity)
    }
}

@MainActor
private final class StudioDocumentBox {
    var value: PaintingDocument

    init(_ value: PaintingDocument) {
        self.value = value
    }
}

private extension WatercolorRenderer {
    func hostChecksum() throws -> UInt64 {
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

private extension PaintingProject {
    static func studioHostTestProject(layerName: String) -> PaintingProject {
        PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: layerName)]
        )
    }
}
