import AppKit
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

/// End-to-end integration coverage for one whole customer session: paint
/// through real pointer events, undo and redo, save and reopen through the
/// production document codec, re-render the reopened document, and export a
/// PNG. Each boundary is covered in isolation elsewhere; this suite proves
/// the boundaries agree with each other.
@MainActor
struct CustomerJourneyIntegrationTests {
    private static func pointerEvent(
        _ type: NSEvent.EventType,
        timestamp: TimeInterval,
        eventNumber: Int,
        location: CGPoint
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1
        )
    }

    private static func paintStroke(
        on view: CanvasEventView,
        in model: StudioModel,
        from start: CGPoint,
        through middle: CGPoint,
        to end: CGPoint,
        startingEventNumber: Int
    ) async throws {
        view.mouseDown(with: try #require(Self.pointerEvent(
            .leftMouseDown,
            timestamp: TimeInterval(startingEventNumber),
            eventNumber: startingEventNumber,
            location: start
        )))
        view.mouseDragged(with: try #require(Self.pointerEvent(
            .leftMouseDragged,
            timestamp: TimeInterval(startingEventNumber) + 0.4,
            eventNumber: startingEventNumber + 1,
            location: middle
        )))
        view.mouseUp(with: try #require(Self.pointerEvent(
            .leftMouseUp,
            timestamp: TimeInterval(startingEventNumber) + 0.8,
            eventNumber: startingEventNumber + 2,
            location: end
        )))
        for _ in 0..<4_000 where model.isStrokePreviewActive {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(!model.isStrokePreviewActive)
    }

    @Test func paintUndoRedoSaveReopenAndExportAgreeAcrossEveryBoundary() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer 1")
        let project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [layer]
        )
        var documentUpdates: [PaintingProject] = []
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(
            project: project,
            renderer: renderer,
            onDocumentUpdate: { documentUpdates.append($0) }
        )
        let view = CanvasEventView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        model.configureCanvas(view)

        // 1. Paint two strokes with different pigments through pointer events.
        model.brush.color = PaintColor.fromSRGB(red: 0.68, green: 0.19, blue: 0.12)
        try await Self.paintStroke(
            on: view,
            in: model,
            from: CGPoint(x: 48, y: 96),
            through: CGPoint(x: 96, y: 96),
            to: CGPoint(x: 140, y: 96),
            startingEventNumber: 1
        )
        model.brush.color = PaintColor.fromSRGB(red: 0.12, green: 0.32, blue: 0.48)
        try await Self.paintStroke(
            on: view,
            in: model,
            from: CGPoint(x: 64, y: 176),
            through: CGPoint(x: 120, y: 176),
            to: CGPoint(x: 176, y: 176),
            startingEventNumber: 10
        )
        #expect(model.project.commands.count == 2)
        #expect(model.error == nil)
        // Pointer y 96 in a 256-point view lands at canvas row 160.
        #expect(try model.rendererForTesting.debugPixel(x: 96, y: 160).alpha > 0.05)

        // 2. Undo removes only the newest stroke; redo restores it.
        model.undo()
        #expect(model.project.commands.count == 1)
        model.redo()
        #expect(model.project.commands.count == 2)
        #expect(model.error == nil)
        #expect(documentUpdates.count == 4)

        // 3. Save and reopen through the production codec.
        let saved = try PaintingDocumentCodec.encode(model.project)
        let reopened = try PaintingDocumentCodec.decode(saved)
        #expect(reopened == model.project)

        // 4. A fresh renderer for the reopened document draws the same pixels
        //    the live session shows after its preview commits and history moves.
        let reopenedRenderer = try WatercolorRenderer(project: reopened, device: device)
        #expect(
            try reopenedRenderer.pixelChecksum()
                == model.rendererForTesting.pixelChecksum()
        )

        // 5. Export writes a decodable PNG at the canvas size.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("journey.png")

        await model.exportPNG(to: destination)

        #expect(model.error == nil)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(source) == UTType.png.identifier as CFString)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == project.canvas.width)
        #expect(image.height == project.canvas.height)
    }
}
