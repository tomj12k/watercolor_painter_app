import Testing
import Foundation
import WatercolorCore
import WatercolorEngine
import WatercolorMCP
@testable import WatercolorStudio

@Suite(.serialized) @MainActor struct MCPDrawingControllerTests {
    @Test func attachingAnOpenCanvasPublishesTheLocalMCPService() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watercolor-mcp-autostart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = MCPBridge(endpointStore: MCPEndpointStore(directoryURL: directory))
        let controller = MCPDrawingController(bridge: bridge)
        let model = try StudioModel(project: .mcpTestProject())

        controller.attach(model: model)

        #expect(controller.isEnabled)
        #expect(try MCPEndpointStore(directoryURL: directory).read() != nil)
        controller.setEnabled(false)
    }

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

    @Test func toolCallsUseMCPContentAndExposeStructuredResults() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }

        let response = await controller.handle(
            MCPJSONRPCRequest(
                id: .number(1),
                method: "tools/call",
                params: .object(["name": .string("canvas_state")])
            )
        )

        #expect(response.error == nil)
        #expect(response.result?["content"]?[0]?["type"] == .string("text"))
        #expect(response.result?["structuredContent"]?["canvas"]?["width"] == .number(256))
    }

    @Test func strokeToolSchemaDescribesPointsAndBrushAttributes() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }

        let response = await controller.handle(
            MCPJSONRPCRequest(id: .number(1), method: "tools/list")
        )
        let tools = try #require(response.result?["tools"])
        guard case let .array(toolValues) = tools else {
            Issue.record("tools/list must return an array")
            return
        }
        let strokeBegin = try #require(toolValues.first(where: { $0["name"] == .string("stroke_begin") }))

        #expect(strokeBegin["inputSchema"]?["properties"]?["points"] != nil)
        #expect(strokeBegin["inputSchema"]?["properties"]?["brush"]?["properties"]?["shape"] != nil)
        #expect(strokeBegin["inputSchema"]?["properties"]?["brush"]?["properties"]?["textureStrength"] != nil)
    }

    @Test func oneShotDrawStrokePaintsAnOpenCanvas() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        defer { controller.setEnabled(false) }
        let points: JSONValue = .array([
            .object(["x": .number(32), "y": .number(32)]),
            .object(["x": .number(96), "y": .number(96)])
        ])

        let response = await controller.handle(
            MCPJSONRPCRequest(
                id: .number(1),
                method: "tools/call",
                params: .object([
                    "name": .string("draw_stroke"),
                    "arguments": .object(["points": points])
                ])
            )
        )

        #expect(response.error == nil)
        #expect(response.result?["structuredContent"]?["committed"] == .bool(true))
        #expect(model.project.commands.count == 1)
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

    @Test func semanticStrokeUsesTheExistingStudioRendererAndHistory() async throws {
        let model = try StudioModel(project: .mcpTestProject())
        let controller = MCPDrawingController(model: model)
        controller.setEnabled(true)
        let point: JSONValue = .object(["x": .number(64), "y": .number(64), "pressure": .number(1), "time": .number(0)])
        let params: JSONValue = .object(["name": .string("stroke_begin"), "arguments": .object(["points": .array([point])])])
        let begin = await controller.handle(MCPJSONRPCRequest(id: .number(2), method: "tools/call", params: params))
        #expect(begin.error == nil)
        let end = await controller.handle(MCPJSONRPCRequest(id: .number(3), method: "tools/call", params: .object(["name": .string("stroke_end"), "arguments": .object([:])])))
        #expect(end.error == nil)
        #expect(model.project.commands.count == 1)
        #expect(model.capabilities.canUndo)
        controller.setEnabled(false)
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
