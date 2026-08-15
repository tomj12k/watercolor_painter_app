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

private struct StudioDocumentView: View {
    @StateObject private var host: StudioDocumentHost

    init(document: Binding<PaintingDocument>) {
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
                    Text(host.failureMessage ?? "The renderer is unavailable.")
                        .foregroundStyle(StudioPalette.graphite)
                }
                .foregroundStyle(StudioPalette.fiber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioPalette.carbon)
                .frame(minWidth: 1_050, minHeight: 680)
            }
        }
    }
}

@MainActor
private final class StudioDocumentHost: ObservableObject {
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

private struct StudioModelFocusKey: FocusedValueKey {
    typealias Value = StudioModel
}

extension FocusedValues {
    var studioModel: StudioModel? {
        get { self[StudioModelFocusKey.self] }
        set { self[StudioModelFocusKey.self] = newValue }
    }
}

private struct StudioAppCommands: Commands {
    @FocusedValue(\.studioModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.requestUndo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!(model?.capabilities.canUndo ?? false))

            Button("Redo") { model?.requestRedo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model?.capabilities.canRedo ?? false))
        }

        CommandMenu("Tools") {
            Button("Brush") { _ = model?.selectTool(forShortcut: "b") }
                .keyboardShortcut("b", modifiers: [])
            Button("Eraser") { _ = model?.selectTool(forShortcut: "e") }
                .keyboardShortcut("e", modifiers: [])
            Button("Water") { _ = model?.selectTool(forShortcut: "w") }
                .keyboardShortcut("w", modifiers: [])
            Button("Smudge") { _ = model?.selectTool(forShortcut: "s") }
                .keyboardShortcut("s", modifiers: [])
            Button("Smear") { _ = model?.selectTool(forShortcut: "m") }
                .keyboardShortcut("m", modifiers: [])
            Button("Dry") { _ = model?.selectTool(forShortcut: "d") }
                .keyboardShortcut("d", modifiers: [])

            Divider()

            Button("Decrease brush size") { model?.adjustBrushSize(by: -1) }
                .keyboardShortcut("[", modifiers: [])
            Button("Increase brush size") { model?.adjustBrushSize(by: 1) }
                .keyboardShortcut("]", modifiers: [])
        }

        CommandMenu("Canvas") {
            Button("Fit canvas") { model?.fitCanvas() }
                .keyboardShortcut("0", modifiers: [.command])

            Button("Dry selected layer") { model?.requestDrySelectedLayer() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(model?.capabilities.canPaint ?? false))

            Divider()

            Button("Export PNG…") { model?.requestPNGExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }
}
