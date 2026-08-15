import Foundation
import Testing
@testable import WatercolorCore

@Suite struct ProjectEditorTests {
    @Test func removingTheOnlyLayerKeepsOneLayer() throws {
        var editor = ProjectEditor(project: .newDefault())

        try editor.removeLayer(id: editor.project.layers[0].id)

        #expect(editor.project.layers.count == 1)
    }

    @Test func undoAndRedoRestoreAStrokeCommand() throws {
        var editor = ProjectEditor(project: .newDefault())
        let command = PaintingCommand.stroke(.fixture(layerID: editor.project.layers[0].id))

        editor.append(command)

        #expect(editor.undo() == command)
        #expect(editor.project.commands.isEmpty)
        #expect(editor.redo() == command)
    }

    @Test func addingALayerCanBeUndoneAndRedone() throws {
        var editor = ProjectEditor(project: .newDefault())
        let original = editor.project

        try editor.addLayer(named: "Sky")
        let added = editor.project

        #expect(added.layers.map(\.name) == ["Layer 1", "Sky"])
        #expect(editor.undo() == nil)
        #expect(editor.project == original)
        #expect(editor.redo() == nil)
        #expect(editor.project == added)
    }

    @Test func duplicatingALayerPreservesItsPropertiesAndCanBeReversed() throws {
        let source = PaintLayer(name: "Clouds", isVisible: false, opacity: 0.4)
        var editor = ProjectEditor(project: project(with: [source]))
        let original = editor.project

        try editor.duplicateLayer(id: source.id)

        #expect(editor.project.layers.count == 2)
        #expect(editor.project.layers[1].name == source.name)
        #expect(editor.project.layers[1].isVisible == source.isVisible)
        #expect(editor.project.layers[1].opacity == source.opacity)
        #expect(editor.project.layers[1].id != source.id)
        try undoAndRedo(&editor, restoring: original)
    }

    @Test func removingALayerPreservesOrderAndCanBeReversed() throws {
        let bottom = PaintLayer(name: "Bottom")
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        var editor = ProjectEditor(project: project(with: [bottom, middle, top]))
        let original = editor.project

        try editor.removeLayer(id: middle.id)

        #expect(editor.project.layers.map(\.id) == [bottom.id, top.id])
        try undoAndRedo(&editor, restoring: original)
    }

    @Test func movingALayerChangesItsIndexAndCanBeReversed() throws {
        let bottom = PaintLayer(name: "Bottom")
        let middle = PaintLayer(name: "Middle")
        let top = PaintLayer(name: "Top")
        var editor = ProjectEditor(project: project(with: [bottom, middle, top]))
        let original = editor.project

        try editor.moveLayer(id: top.id, to: 0)

        #expect(editor.project.layers.map(\.id) == [top.id, bottom.id, middle.id])
        try undoAndRedo(&editor, restoring: original)
    }

    @Test func mergingALayerDownAppendsACommandAndCanBeReversed() throws {
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var editor = ProjectEditor(project: project(with: [bottom, top]))
        let original = editor.project

        try editor.mergeDown(id: top.id)
        let merged = editor.project

        #expect(merged.layers == [bottom])
        #expect(merged.commands.count == 1)
        if let firstCommand = merged.commands.first, case let .mergeDown(command) = firstCommand {
            #expect(command.sourceLayerID == top.id)
            #expect(command.destinationLayerID == bottom.id)
        } else {
            Issue.record("Expected one merge-down command")
        }
        #expect(editor.undo()?.id == merged.commands.first?.id)
        #expect(editor.project == original)
        #expect(editor.redo()?.id == merged.commands.first?.id)
        #expect(editor.project == merged)
    }

    @Test func editingAMissingLayerIsRejected() {
        var editor = ProjectEditor(project: .newDefault())
        let missing = UUID()

        #expect(throws: ProjectEditingError.layerNotFound(missing)) {
            try editor.removeLayer(id: missing)
        }
    }

    @Test func addingPastTheLayerLimitIsRejected() throws {
        var editor = ProjectEditor(project: project(with: (1...12).map { PaintLayer(name: "Layer \($0)") }))

        #expect(throws: ProjectEditingError.self) {
            try editor.addLayer(named: "Too many")
        }
        #expect(editor.project.layers.count == 12)
    }

    @Test func aNewCommandClearsRedoHistory() throws {
        var editor = ProjectEditor(project: .newDefault())
        let layerID = editor.project.layers[0].id
        let first = PaintingCommand.stroke(.fixture(layerID: layerID))
        let second = PaintingCommand.clearLayer(LayerCommand(layerID: layerID))

        editor.append(first)
        _ = editor.undo()
        editor.append(second)

        #expect(!editor.canRedo)
        #expect(editor.redo() == nil)
        #expect(editor.project.commands == [second])
    }
}

private extension StrokeCommand {
    static func fixture(layerID: UUID) -> Self {
        Self(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            layerID: layerID,
            tool: .brush,
            brush: .default,
            points: [StrokePoint(x: 1, y: 1, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}

private func project(with layers: [PaintLayer]) -> PaintingProject {
    PaintingProject(
        canvas: CanvasSize(width: 1600, height: 1200),
        paper: .coldPress,
        layers: layers
    )
}

private func undoAndRedo(_ editor: inout ProjectEditor, restoring original: PaintingProject) throws {
    let changed = editor.project

    #expect(editor.undo() == nil)
    #expect(editor.project == original)
    #expect(editor.redo() == nil)
    #expect(editor.project == changed)
}
