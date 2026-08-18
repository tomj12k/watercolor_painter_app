import Testing
import Foundation
import WatercolorCore
import WatercolorEngine
import WatercolorMCP
@testable import WatercolorStudio

@Suite(.serialized) @MainActor struct MCPDrawingControllerTests {
    @Test func controlIsOffByDefaultAndDoesNotAdvertiseAnEndpoint() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        #expect(!controller.isEnabled)
        #expect(!controller.isConnected)
        let response = await controller.handle(
            MCPJSONRPCRequest(id: .number(1), method: "tools/list")
        )
        #expect(response.error?.code == .permissionDenied)
    }

    @Test func enabledControllerAdvertisesSemanticTools() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        let response = await controller.handle(
            MCPJSONRPCRequest(id: .number(1), method: "tools/list")
        )
        #expect(response.error == nil)
        #expect(response.result?["tools"]?[0]?["name"] != nil)
        controller.setEnabled(false)
    }

    @Test func stopSessionCancelsPreviewAndClearsConnectionState() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        controller.stopSession()
        #expect(!controller.isConnected)
        controller.setEnabled(false)
    }

    @Test func disablingRemovesThePublishedEndpointAndSocket() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watercolor-mcp-controller-\(UUID().uuidString)", isDirectory: true)
        let bridge = MCPBridge(endpointStore: MCPEndpointStore(directoryURL: directory))
        let controller = MCPDrawingController(bridge: bridge)
        controller.setEnabled(true)
        let descriptor = try #require(try MCPEndpointStore(directoryURL: directory).read())
        #expect(FileManager.default.fileExists(atPath: descriptor.socketPath))
        controller.setEnabled(false)
        #expect(try MCPEndpointStore(directoryURL: directory).read() == nil)
        #expect(!FileManager.default.fileExists(atPath: descriptor.socketPath))
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension PaintingProject {
    static func mcpTestProject() -> Self {
        Self(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer 1")]
        )
    }
}
