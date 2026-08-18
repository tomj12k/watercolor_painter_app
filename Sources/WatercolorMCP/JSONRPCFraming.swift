import Foundation

public enum MCPFramingError: Error, Equatable, Sendable {
    case frameTooLarge
    case invalidJSON
}

public enum JSONRPCLineFramer {
    public static let maximumFrameBytes = 1_048_576

    public static func decode(_ data: Data) throws -> MCPJSONRPCRequest {
        guard data.count <= maximumFrameBytes else { throw MCPFramingError.frameTooLarge }
        do {
            return try JSONDecoder().decode(MCPJSONRPCRequest.self, from: data)
        } catch {
            throw MCPFramingError.invalidJSON
        }
    }

    public static func encode(_ response: MCPJSONRPCResponse) throws -> Data {
        try JSONEncoder().encode(response) + Data([0x0A])
    }
}

