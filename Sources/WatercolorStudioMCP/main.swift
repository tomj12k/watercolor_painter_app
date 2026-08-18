import Foundation
import WatercolorMCP

@main
struct WatercolorStudioMCPMain {
    static func main() async {
        let store = MCPEndpointStore()
        let server = MCPServer { request in
            guard let descriptor = try store.read() else {
                throw MCPRPCError(
                    code: .bridgeUnavailable,
                    message: "Open a Watercolor Studio canvas, then try again."
                )
            }
            let bridgeResponse = try MCPUnixSocketClient().send(
                descriptor: descriptor,
                request: MCPBridgeRequest(token: descriptor.token, request: request)
            )
            return bridgeResponse.response
        }

        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8) else { continue }
            let response: MCPJSONRPCResponse
            do {
                response = await server.handle(try JSONRPCLineFramer.decode(data))
            } catch {
                response = MCPJSONRPCResponse(
                    id: nil,
                    error: MCPRPCError(code: .parseError, message: "Invalid MCP request.")
                )
            }
            if let encoded = try? JSONRPCLineFramer.encode(response) {
                FileHandle.standardOutput.write(encoded)
            }
        }
    }
}
