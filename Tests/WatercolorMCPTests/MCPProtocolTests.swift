import Foundation
import Testing
@testable import WatercolorMCP

@Suite struct MCPProtocolTests {
    @Test func serverNegotiatesAndForwardsToolCalls() async throws {
        let server = MCPServer { request in
            MCPJSONRPCResponse(
                id: request.id,
                result: .object(["forwarded": .string(request.method)])
            )
        }
        let initialize = await server.handle(
            MCPJSONRPCRequest(id: .number(1), method: "initialize")
        )
        #expect(initialize.error == nil)
        #expect(initialize.result?["serverInfo"]?["name"] == .string("WatercolorStudioMCP"))

        let call = await server.handle(
            MCPJSONRPCRequest(
                id: .number(2),
                method: "tools/call",
                params: .object(["name": .string("canvas_state")])
            )
        )
        #expect(call.error == nil)
        #expect(call.result == .object(["forwarded": .string("tools/call")]))
    }

    @Test func serverRejectsUnknownMethods() async throws {
        let server = MCPServer { _ in
            MCPJSONRPCResponse(id: nil, result: .null)
        }
        let response = await server.handle(
            MCPJSONRPCRequest(id: .number(1), method: "not/a/method")
        )
        #expect(response.error?.code == .methodNotFound)
    }

    @Test func unavailableBridgeExplainsHowToMakeACanvasAvailable() async throws {
        let server = MCPServer { _ in
            throw MCPRPCError(code: .bridgeUnavailable, message: "Endpoint missing")
        }

        let response = await server.handle(
            MCPJSONRPCRequest(id: .number(1), method: "tools/list")
        )

        #expect(response.error?.code == .bridgeUnavailable)
        #expect(response.error?.message == "Open a Watercolor Studio canvas, then try again.")
    }

    @Test func requestRoundTripsWithObjectArguments() throws {
        let request = MCPJSONRPCRequest(
            id: .number(7),
            method: "tools/call",
            params: .object(["name": .string("canvas_state")])
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MCPJSONRPCRequest.self, from: data)
        #expect(decoded == request)
    }

    @Test func notificationHasNoIdentifier() throws {
        let request = try JSONDecoder().decode(
            MCPJSONRPCRequest.self,
            from: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        #expect(request.id == nil)
        #expect(request.method == "notifications/initialized")
    }

    @Test func responseEncodesErrorWithoutResult() throws {
        let response = MCPJSONRPCResponse(
            id: .string("abc"),
            error: MCPRPCError(code: .invalidParams, message: "Invalid arguments")
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["result"] == nil)
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func lineFramingRejectsOversizedFrames() throws {
        let oversized = Data(repeating: 65, count: JSONRPCLineFramer.maximumFrameBytes + 1)
        #expect(throws: MCPFramingError.frameTooLarge) {
            try JSONRPCLineFramer.decode(oversized)
        }
    }

    @Test func toolInputSchemaIsExplicitObject() throws {
        let tool = MCPTool(
            name: "canvas_state",
            description: "Read the current canvas state.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false)
            ])
        )
        let decoded = try JSONDecoder().decode(MCPTool.self, from: JSONEncoder().encode(tool))
        #expect(decoded.inputSchema == tool.inputSchema)
    }
}
