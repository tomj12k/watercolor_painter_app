import Foundation
import Testing
@testable import WatercolorMCP

@Suite struct MCPProtocolTests {
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

