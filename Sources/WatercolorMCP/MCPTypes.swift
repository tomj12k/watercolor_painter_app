import Foundation

public enum MCPRequestID: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let method: String
    public let params: JSONValue?

    public init(id: MCPRequestID? = nil, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
            throw MCPProtocolError.invalidJSONRPCVersion
        }
        jsonrpc = "2.0"
        id = try container.decodeIfPresent(MCPRequestID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
}

public struct MCPRPCError: Codable, Equatable, Sendable {
    public enum Code: Int, Codable, Sendable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        case bridgeUnavailable = -32001
        case permissionDenied = -32002
        case busy = -32003
    }

    public let code: Code
    public let message: String
    public let data: JSONValue?

    public init(code: Code, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let result: JSONValue?
    public let error: MCPRPCError?

    public init(id: MCPRequestID?, result: JSONValue? = nil, error: MCPRPCError? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct MCPTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPBridgeRequest: Codable, Sendable {
    public let token: String
    public let request: MCPJSONRPCRequest

    public init(token: String, request: MCPJSONRPCRequest) {
        self.token = token
        self.request = request
    }
}

public struct MCPBridgeResponse: Codable, Sendable {
    public let response: MCPJSONRPCResponse

    public init(response: MCPJSONRPCResponse) { self.response = response }
}

public struct MCPEndpointDescriptor: Codable, Equatable, Sendable {
    public let socketPath: String
    public let token: String
    public let protocolVersion: String

    public init(socketPath: String, token: String, protocolVersion: String) {
        self.socketPath = socketPath
        self.token = token
        self.protocolVersion = protocolVersion
    }
}

public enum MCPProtocolError: Error, Equatable, Sendable {
    case invalidJSONRPCVersion
    case invalidRequest
}

