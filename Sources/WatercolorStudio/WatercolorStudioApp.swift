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

private struct StudioModelFocusKey: FocusedValueKey {
    typealias Value = StudioModel
}

private struct StudioTextEntryFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var studioModel: StudioModel? {
        get { self[StudioModelFocusKey.self] }
        set { self[StudioModelFocusKey.self] = newValue }
    }

    var studioTextEntryIsFocused: Bool? {
        get { self[StudioTextEntryFocusKey.self] }
        set { self[StudioTextEntryFocusKey.self] = newValue }
    }
}

enum StudioShortcutRouter {
    private static let barePaintingShortcuts: Set<String> = ["b", "e", "w", "s", "m", "d", "[", "]"]

    static func allowsBarePaintingShortcut(
        _ key: String,
        textEntryIsFocused: Bool
    ) -> Bool {
        barePaintingShortcuts.contains(key.lowercased()) && !textEntryIsFocused
    }
}

private struct StudioAppCommands: Commands {
    @FocusedValue(\.studioModel) private var model
    @FocusedValue(\.studioTextEntryIsFocused) private var textEntryIsFocused

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
                .disabled(!allowsBareShortcut("b"))
            Button("Eraser") { _ = model?.selectTool(forShortcut: "e") }
                .keyboardShortcut("e", modifiers: [])
                .disabled(!allowsBareShortcut("e"))
            Button("Water") { _ = model?.selectTool(forShortcut: "w") }
                .keyboardShortcut("w", modifiers: [])
                .disabled(!allowsBareShortcut("w"))
            Button("Smudge") { _ = model?.selectTool(forShortcut: "s") }
                .keyboardShortcut("s", modifiers: [])
                .disabled(!allowsBareShortcut("s"))
            Button("Smear") { _ = model?.selectTool(forShortcut: "m") }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!allowsBareShortcut("m"))
            Button("Dry") { _ = model?.selectTool(forShortcut: "d") }
                .keyboardShortcut("d", modifiers: [])
                .disabled(!allowsBareShortcut("d"))

            Divider()

            Button("Decrease brush size") { model?.adjustBrushSize(by: -1) }
                .keyboardShortcut("[", modifiers: [])
                .disabled(!allowsBareShortcut("["))
            Button("Increase brush size") { model?.adjustBrushSize(by: 1) }
                .keyboardShortcut("]", modifiers: [])
                .disabled(!allowsBareShortcut("]"))
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

    private func allowsBareShortcut(_ key: String) -> Bool {
        model != nil && StudioShortcutRouter.allowsBarePaintingShortcut(
            key,
            textEntryIsFocused: textEntryIsFocused ?? false
        )
    }
}
