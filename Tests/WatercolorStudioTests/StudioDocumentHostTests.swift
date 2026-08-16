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
        #expect(host.failure?.message == "renderer initialization failed")

        host.dismissFailure()
        #expect(host.failure == nil)
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
        #expect(host.failure?.message.contains("canvas texture allocation failed") == true)
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
        #expect(host.failure?.message == "default canvas allocation failed")
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
        #expect(
            host.failure?.message.contains("Reduce the canvas size or layer count.") == true
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
