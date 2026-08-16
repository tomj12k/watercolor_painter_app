import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine
@testable import WatercolorStudio

struct PaperChangeAfterLongStrokesTests {
    private func rgbaBytes(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    @Test @MainActor func exportDuringAPaperChangeWritesTheChosenSurface() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer 1")
        let project = PaintingProject(
            canvas: CanvasSize(width: 640, height: 480),
            paper: .coldPress,
            layers: [layer]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        let points: [StrokePoint] = (0..<160).map { (index: Int) -> StrokePoint in
            StrokePoint(
                x: 40 + Double(index) * 3.5,
                y: 240 + sin(Double(index) * 0.3) * 90,
                pressure: 0.85,
                tiltX: 0,
                tiltY: 0,
                time: Double(index) / 160
            )
        }
        let stroke = StrokeCommand(layerID: layer.id, tool: .brush, brush: .default, points: points)
        var initial = stroke
        initial.points = [stroke.points[0]]
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()
        await model.commitStrokePreview(stroke)

        // Exporting while the new surface prepares must produce the painting
        // the customer just chose, never a stale file with the old paper.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-swap-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        model.selectPaper(.rough)
        #expect(model.isApplyingSurfaceChange)
        await model.exportPNG(to: destination)
        await model.waitForStructuralChanges()
        #expect(model.error == nil)
        #expect(model.project.paper == .rough)

        let source = try #require(
            CGImageSourceCreateWithURL(destination as CFURL, nil)
        )
        let exported = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        let expected = try WatercolorRenderer(project: model.project, device: device)
            .makeCGImage()
        // Compare a digest, not the raw arrays: a failure diff over millions
        // of bytes would stall the test runner.
        let exportedBytes = rgbaBytes(of: exported)
        let expectedBytes = rgbaBytes(of: expected)
        let mismatched = zip(exportedBytes, expectedBytes).lazy.filter { $0 != $1 }.count
        #expect(exportedBytes.count == expectedBytes.count)
        #expect(mismatched == 0)
    }

    @Test @MainActor func changingPaperAfterPaintingLongStrokesStaysResponsive() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layer = PaintLayer(name: "Layer 1")
        let project = PaintingProject(
            canvas: CanvasSize(width: 1_600, height: 1_200),
            paper: .coldPress,
            layers: [layer]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let model = StudioModel(project: project, renderer: renderer)

        // Paint a long continuous stroke through the live preview path.
        let points: [StrokePoint] = (0..<240).map { (index: Int) -> StrokePoint in
            let x = 40 + Double(index) * 5.5
            let y = 600 + sin(Double(index) * 0.2) * 120
            return StrokePoint(x: x, y: y, pressure: 0.8, tiltX: 0, tiltY: 0, time: Double(index) / 240)
        }
        let stroke = StrokeCommand(layerID: layer.id, tool: .brush, brush: .default, points: points)
        var initial = stroke
        initial.points = [stroke.points[0]]
        #expect(model.beginStrokePreview(initial) == .accepted)
        model.appendStrokePreview(id: stroke.id, points: Array(stroke.points.dropFirst()))
        await model.waitForStrokePreviewIdle()
        await model.commitStrokePreview(stroke)
        #expect(model.project.commands.count == 1)

        // Changing paper replays the painting, so it must not block the main
        // thread: the call returns immediately with editing paused, and the
        // new surface applies when the replay finishes.
        model.selectPaper(.rough)
        #expect(model.project.paper == .coldPress)
        #expect(!model.capabilities.canPaint)
        #expect(!model.canModifyProject)
        // The pause must be visible: the studio shows why editing is paused
        // while the new surface prepares, and the paper picker already
        // reflects the choice the customer made.
        #expect(model.isApplyingSurfaceChange)
        #expect(model.displayedPaper == .rough)

        for _ in 0..<4_000 where model.project.paper != .rough {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.project.paper == .rough)
        #expect(model.displayedPaper == .rough)
        #expect(model.capabilities.canPaint)
        #expect(model.canModifyProject)
        #expect(!model.isApplyingSurfaceChange)
        #expect(model.capabilities.canUndo)
        #expect(model.rendererRecoveryError == nil)
        #expect(model.error == nil)

        // The asynchronously applied surface renders exactly what reopening
        // the saved painting would.
        let reopened = try WatercolorRenderer(project: model.project, device: device)
        #expect(
            try model.rendererForTesting.pixelChecksum() == reopened.pixelChecksum()
        )

        // Undo restores the previous surface through the same non-blocking flow.
        model.undo()
        #expect(model.project.paper == .coldPress)
    }
}
