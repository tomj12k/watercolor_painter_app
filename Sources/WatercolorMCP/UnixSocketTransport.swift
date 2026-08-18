import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum MCPTransportError: Error, Equatable, Sendable {
    case socketUnavailable
    case connectionFailed
    case writeFailed
    case readFailed
    case invalidResponse
}

public struct MCPUnixSocketClient: Sendable {
    public init() {}

    public func send(
        descriptor: MCPEndpointDescriptor,
        request: MCPBridgeRequest
    ) throws -> MCPBridgeResponse {
#if canImport(Darwin)
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw MCPTransportError.socketUnavailable }
        defer { close(fileDescriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(descriptor.socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MCPTransportError.connectionFailed
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { throw MCPTransportError.connectionFailed }

        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        try writeAll(payload, to: fileDescriptor)
        var response = Data()
        var byte: UInt8 = 0
        repeat {
            let count = read(fileDescriptor, &byte, 1)
            guard count == 1 else { throw MCPTransportError.readFailed }
            response.append(byte)
            guard response.count <= JSONRPCLineFramer.maximumFrameBytes else {
                throw MCPFramingError.frameTooLarge
            }
        } while byte != 0x0A
        response.removeLast()
        do {
            return try JSONDecoder().decode(MCPBridgeResponse.self, from: response)
        } catch {
            throw MCPTransportError.invalidResponse
        }
#else
        throw MCPTransportError.socketUnavailable
#endif
    }

#if canImport(Darwin)
    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw MCPTransportError.writeFailed }
                offset += count
            }
        }
    }
#endif
}

