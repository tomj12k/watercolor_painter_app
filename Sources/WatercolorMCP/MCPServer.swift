import Foundation

public struct MCPServer: Sendable {
    public typealias BridgeCall = @Sendable (MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse

    private let bridgeCall: BridgeCall

    public init(bridgeCall: @escaping BridgeCall) {
        self.bridgeCall = bridgeCall
    }

    public func handle(_ request: MCPJSONRPCRequest) async -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(
                id: request.id,
                result: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string("WatercolorStudioMCP"),
                        "version": .string("1.0")
                    ])
                ])
            )
        case "notifications/initialized":
            return MCPJSONRPCResponse(id: nil, result: .null)
        case "tools/list", "tools/call":
            do {
                return try await bridgeCall(request)
            } catch {
                return MCPJSONRPCResponse(
                    id: request.id,
                    error: MCPRPCError(
                        code: .bridgeUnavailable,
                        message: "Open a Watercolor Studio canvas, then try again."
                    )
                )
            }
        default:
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPRPCError(code: .methodNotFound, message: "MCP method is not supported.")
            )
        }
    }
}
