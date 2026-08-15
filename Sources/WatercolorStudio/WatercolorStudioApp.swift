import Combine
import SwiftUI
import WatercolorCore

@main
struct WatercolorStudioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: PaintingDocument()) { configuration in
            StudioDocumentView(document: configuration.$document)
        }
        .defaultSize(width: 1_220, height: 790)
        .commands {
            StudioAppCommands()
        }
    }
}

struct StudioDocumentView: View {
    @Binding private var document: PaintingDocument
    @StateObject private var host: StudioDocumentHost

    init(document: Binding<PaintingDocument>) {
        _document = document
        _host = StateObject(wrappedValue: StudioDocumentHost(document: document))
    }

    var body: some View {
        Group {
            if let model = host.model {
                StudioView(model: model)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                    Text("Watercolor Studio could not open this painting")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                    Text("The renderer is unavailable.")
                        .foregroundStyle(StudioPalette.graphite)
                }
                .foregroundStyle(StudioPalette.fiber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioPalette.carbon)
                .frame(minWidth: 1_050, minHeight: 680)
            }
        }
        .onChange(of: document.project) { _, project in
            host.receiveDocumentProject(project)
        }
        .alert(item: failureBinding) { failure in
            Alert(
                title: Text("Studio issue"),
                message: Text(failure.message),
                dismissButton: .default(Text("Dismiss")) { host.dismissFailure() }
            )
        }
    }

    private var failureBinding: Binding<StudioFailure?> {
        Binding(
            get: { host.failure },
            set: { value in
                if value == nil { host.dismissFailure() }
            }
        )
    }
}

@MainActor
final class StudioDocumentHost: ObservableObject {
    typealias ModelFactory = (
        _ project: PaintingProject,
        _ onDocumentUpdate: @escaping (PaintingProject) -> Void
    ) throws -> StudioModel

    let model: StudioModel?
    @Published private(set) var failure: StudioFailure?
    private var failureSubscription: AnyCancellable?

    init(
        document: Binding<PaintingDocument>,
        modelFactory: ModelFactory = { project, onDocumentUpdate in
            try StudioModel(project: project, onDocumentUpdate: onDocumentUpdate)
        }
    ) {
        failureSubscription = nil
        do {
            let createdModel = try modelFactory(
                document.wrappedValue.project,
                { project in
                    guard document.wrappedValue.project != project else { return }
                    document.wrappedValue.project = project
                }
            )
            model = createdModel
            failure = nil
            failureSubscription = createdModel.$error.sink { [weak self] failure in
                self?.failure = failure
            }
        } catch {
            model = nil
            failure = StudioFailure(message: error.localizedDescription)
        }
    }

    func receiveDocumentProject(_ project: PaintingProject) {
        guard model?.project != project else { return }
        model?.replaceProjectFromDocument(project)
    }

    func dismissFailure() {
        model?.dismissError()
        failure = nil
    }
}
