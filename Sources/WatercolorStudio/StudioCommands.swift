import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

@MainActor
enum StudioPNGExportPanel {
    static func present(for model: StudioModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Watercolor.png"
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            Task { @MainActor in
                await model.exportPNG(to: destinationURL)
            }
        }
    }
}

struct StudioAppCommands: Commands {
    @FocusedValue(\.studioModel) private var model
    @FocusedValue(\.studioTextEntryIsFocused) private var textEntryIsFocused

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.undo() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!(model?.capabilities.canUndo ?? false))

            Button("Redo") { model?.redo() }
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

            Button("Dry selected layer") { model?.drySelectedLayer() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(model?.capabilities.canPaint ?? false))

            Divider()

            Button("Export PNG…") {
                guard let model else { return }
                StudioPNGExportPanel.present(for: model)
            }
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
