import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine

@Suite @MainActor struct ReplayAndExportTests {
    @Test func replayProducesEquivalentPixelsInIndependentRenderers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.twoColorFixture()
        let first = try WatercolorRenderer(project: project, device: device)
        try first.replay(project: project)
        let expected = try first.pixelChecksum()
        let second = try WatercolorRenderer(project: project, device: device)

        try second.replay(project: project)

        #expect(try second.pixelChecksum() == expected)
    }
}

private extension PaintingProject {
    static func twoColorFixture() -> Self {
        let bottom = PaintLayer(
            id: UUID(uuidString: "FAE123C6-F824-4D63-895A-5991B1FD74DD")!,
            name: "Vermilion"
        )
        let top = PaintLayer(
            id: UUID(uuidString: "11E3D686-0DD3-439D-B7AF-D15E45B0DCB7")!,
            name: "Cobalt",
            opacity: 0.7
        )
        return Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [bottom, top],
            commands: [
                .stroke(.fixture(
                    id: UUID(uuidString: "05903909-91A0-4C23-AB72-A4DC0D2FC596")!,
                    layerID: bottom.id,
                    color: PaintColor(red: 0.9, green: 0.2, blue: 0.1),
                    x: 104,
                    y: 128
                )),
                .stroke(.fixture(
                    id: UUID(uuidString: "7610C48B-F92F-43E5-8DBF-D31496770656")!,
                    layerID: top.id,
                    color: PaintColor(red: 0.1, green: 0.3, blue: 0.9),
                    x: 152,
                    y: 128
                ))
            ]
        )
    }
}

private extension StrokeCommand {
    static func fixture(
        id: UUID,
        layerID: UUID,
        color: PaintColor,
        x: Double,
        y: Double
    ) -> Self {
        var brush = BrushSettings.default
        brush.color = color
        brush.opacity = 0.8
        brush.flow = 0.8
        return Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: [StrokePoint(x: x, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: 0)]
        )
    }
}
