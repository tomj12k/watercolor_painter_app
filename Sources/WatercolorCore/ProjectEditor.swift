import Foundation

public enum ProjectEditingError: Error, Equatable, Sendable {
    case layerNotFound(UUID)
    case layerLimitExceeded(Int)
    case invalidLayerIndex(Int)
    case cannotMergeBottomLayer(UUID)
}

public struct ProjectEditor: Sendable {
    private static let maximumHistoryEntries = 100

    public private(set) var project: PaintingProject

    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []

    public init(project: PaintingProject) {
        self.project = project
    }

    public var canUndo: Bool {
        !undoHistory.isEmpty
    }

    public var canRedo: Bool {
        !redoHistory.isEmpty
    }

    public mutating func removeLayer(id: UUID) throws {
        let index = try layerIndex(for: id)

        guard project.layers.count > 1 else {
            return
        }

        let before = project
        project.layers.remove(at: index)
        recordChange(before: before)
    }

    public mutating func addLayer(named name: String) throws {
        try ensureLayerCapacity()

        let before = project
        project.layers.append(PaintLayer(name: name))
        recordChange(before: before)
    }

    public mutating func duplicateLayer(id: UUID, named name: String? = nil) throws {
        let index = try layerIndex(for: id)
        try ensureLayerCapacity()

        let before = project
        let source = project.layers[index]
        let duplicate = PaintLayer(
            name: name ?? source.name,
            isVisible: source.isVisible,
            opacity: source.opacity
        )
        project.layers.insert(duplicate, at: index + 1)
        let command = PaintingCommand.duplicateLayer(
            DuplicateLayerCommand(
                sourceLayerID: source.id,
                destinationLayerID: duplicate.id
            )
        )
        project.commands.append(command)
        recordChange(before: before, command: command)
    }

    public mutating func renameLayer(id: UUID, to name: String) throws {
        let index = try layerIndex(for: id)
        guard project.layers[index].name != name else { return }

        let before = project
        project.layers[index].name = name
        recordChange(before: before)
    }

    public mutating func setLayerVisibility(id: UUID, isVisible: Bool) throws {
        let index = try layerIndex(for: id)
        guard project.layers[index].isVisible != isVisible else { return }

        let before = project
        project.layers[index].isVisible = isVisible
        recordChange(before: before)
    }

    public mutating func setLayerOpacity(id: UUID, opacity: Double) throws {
        let index = try layerIndex(for: id)
        guard project.layers[index].opacity != opacity else { return }

        let before = project
        project.layers[index].opacity = opacity
        recordChange(before: before)
    }

    public mutating func setPaper(_ paper: PaperTexture) {
        guard project.paper != paper else { return }

        let before = project
        project.paper = paper
        recordChange(before: before)
    }

    public mutating func moveLayer(id: UUID, to destinationIndex: Int) throws {
        let sourceIndex = try layerIndex(for: id)
        guard project.layers.indices.contains(destinationIndex) else {
            throw ProjectEditingError.invalidLayerIndex(destinationIndex)
        }

        guard sourceIndex != destinationIndex else {
            return
        }

        let before = project
        let layer = project.layers.remove(at: sourceIndex)
        project.layers.insert(layer, at: destinationIndex)
        recordChange(before: before)
    }

    public mutating func mergeDown(id: UUID) throws {
        let sourceIndex = try layerIndex(for: id)
        guard sourceIndex > 0 else {
            throw ProjectEditingError.cannotMergeBottomLayer(id)
        }

        let before = project
        let sourceLayer = project.layers[sourceIndex]
        let destinationLayer = project.layers[sourceIndex - 1]
        let command = PaintingCommand.mergeDown(
            MergeDownCommand(
                sourceLayerID: sourceLayer.id,
                destinationLayerID: destinationLayer.id
            )
        )
        project.layers.remove(at: sourceIndex)
        project.commands.append(command)
        recordChange(before: before, command: command)
    }

    public mutating func append(_ command: PaintingCommand) {
        let before = project
        project.commands.append(command)
        recordChange(before: before, command: command)
    }

    @discardableResult
    public mutating func undo() -> PaintingCommand? {
        guard let entry = undoHistory.popLast() else {
            return nil
        }

        project = entry.before
        Self.append(entry, to: &redoHistory)
        return entry.command
    }

    @discardableResult
    public mutating func redo() -> PaintingCommand? {
        guard let entry = redoHistory.popLast() else {
            return nil
        }

        project = entry.after
        Self.append(entry, to: &undoHistory)
        return entry.command
    }

    private mutating func recordChange(before: PaintingProject, command: PaintingCommand? = nil) {
        Self.append(HistoryEntry(before: before, after: project, command: command), to: &undoHistory)
        redoHistory.removeAll()
    }

    private static func append(_ entry: HistoryEntry, to history: inout [HistoryEntry]) {
        history.append(entry)
        if history.count > maximumHistoryEntries {
            history.removeFirst(history.count - maximumHistoryEntries)
        }
    }

    private func layerIndex(for id: UUID) throws -> Int {
        guard let index = project.layers.firstIndex(where: { $0.id == id }) else {
            throw ProjectEditingError.layerNotFound(id)
        }
        return index
    }

    private func ensureLayerCapacity() throws {
        guard project.layers.count < PaintingProject.maximumLayerCount else {
            throw ProjectEditingError.layerLimitExceeded(project.layers.count)
        }
    }
}

private struct HistoryEntry: Sendable {
    let before: PaintingProject
    let after: PaintingProject
    let command: PaintingCommand?
}
