import SwiftUI
import Testing
import WatercolorCore
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
}

@MainActor
private final class StudioDocumentBox {
    var value: PaintingDocument

    init(_ value: PaintingDocument) {
        self.value = value
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
