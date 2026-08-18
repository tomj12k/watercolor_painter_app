import Foundation
import WatercolorCore
import WatercolorMCP

@MainActor
final class MCPDrawingController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var sessionLabel: String?

    private weak var model: StudioModel?
    private let bridge: MCPBridge

    init(model: StudioModel? = nil, bridge: MCPBridge = MCPBridge()) {
        self.model = model
        self.bridge = bridge
        bridge.requestHandler = { [weak self] request in
            guard let self else {
                return MCPJSONRPCResponse(
                    id: request.id,
                    error: MCPRPCError(code: .bridgeUnavailable, message: "Watercolor Studio is unavailable.")
                )
            }
            self.isConnected = true
            self.sessionLabel = "Local AI session"
            return await self.handle(request)
        }
    }

    func attach(model: StudioModel) {
        self.model = model
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            do {
                try bridge.start()
                isEnabled = true
            } catch {
                isEnabled = false
                sessionLabel = nil
            }
        } else {
            stopSession()
            bridge.stop()
            isEnabled = false
        }
    }

    func stopSession() {
        model?.cancelStrokePreview()
        isConnected = false
        sessionLabel = nil
    }

    func handle(_ request: MCPJSONRPCRequest) async -> MCPJSONRPCResponse {
        guard isEnabled else {
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPRPCError(code: .permissionDenied, message: "AI Control is turned off in Watercolor Studio.")
            )
        }
        switch request.method {
        case "tools/list":
            return MCPJSONRPCResponse(
                id: request.id,
                result: .object(["tools": .array(Self.toolCatalog.map(Self.toolJSON))])
            )
        default:
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPRPCError(code: .methodNotFound, message: "This painting tool is not available yet.")
            )
        }
    }

    private static let toolCatalog: [MCPTool] = [
        MCPTool(name: "canvas_state", description: "Read the current watercolor canvas state.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "brush_catalog", description: "List watercolor tools and brush options.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_begin", description: "Begin an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_append", description: "Append points to an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_end", description: "Commit an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_cancel", description: "Cancel the active AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "undo", description: "Undo the latest painting command.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "redo", description: "Redo the latest painting command.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "export_png", description: "Export the current painting as PNG.", inputSchema: .object(["type": .string("object")]))
    ]

    private static func toolJSON(_ tool: MCPTool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema
        ])
    }
}

