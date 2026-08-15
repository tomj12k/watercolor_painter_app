import SwiftUI
import WatercolorCore

@main
struct WatercolorStudioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: PaintingDocument()) { configuration in
            StudioDiagnosticView(document: configuration.$document)
        }
    }
}

private struct StudioDiagnosticView: View {
    @StateObject private var host: StudioDiagnosticHost

    init(document: Binding<PaintingDocument>) {
        _host = StateObject(wrappedValue: StudioDiagnosticHost(document: document))
    }

    var body: some View {
        Group {
            if let model = host.model {
                VStack(spacing: 8) {
                    Text("Watercolor Studio")
                        .font(.headline)
                    Text("\(model.project.canvas.width) × \(model.project.canvas.height)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(host.failureMessage ?? "Watercolor Studio could not start.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

@MainActor
private final class StudioDiagnosticHost: ObservableObject {
    let model: StudioModel?
    let failureMessage: String?

    init(document: Binding<PaintingDocument>) {
        do {
            model = try StudioModel(
                project: document.wrappedValue.project,
                onDocumentUpdate: { project in
                    document.wrappedValue.project = project
                }
            )
            failureMessage = nil
        } catch {
            model = nil
            failureMessage = error.localizedDescription
        }
    }
}
