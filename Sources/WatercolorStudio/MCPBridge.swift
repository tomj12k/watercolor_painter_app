import Foundation
import WatercolorMCP

#if canImport(Darwin)
import Darwin
#endif

@MainActor
final class MCPBridge: ObservableObject {
    typealias RequestHandler = @MainActor @Sendable (MCPJSONRPCRequest) async -> MCPJSONRPCResponse

    private let endpointStore: MCPEndpointStore
    private var listenerFileDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var activeToken: String?
    private var activeSocketPath: String?
    private(set) var isRunning = false
    var requestHandler: RequestHandler?

    init(endpointStore: MCPEndpointStore = MCPEndpointStore()) {
        self.endpointStore = endpointStore
    }

    func start() throws {
        guard !isRunning else { return }
#if canImport(Darwin)
        // Keep the sockaddr_un path comfortably below macOS's 104-byte limit;
        // Application Support and test temp paths can exceed it.
        let socketPath = "/tmp/watercolor-studio-mcp-\(UUID().uuidString).sock"
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw MCPTransportError.socketUnavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fileDescriptor)
            throw MCPTransportError.connectionFailed
        }
        unlink(socketPath)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound, listen(fileDescriptor, 1) == 0 else {
            close(fileDescriptor)
            unlink(socketPath)
            throw MCPTransportError.connectionFailed
        }
        let token = UUID().uuidString + UUID().uuidString
        do {
            try endpointStore.publish(
                MCPEndpointDescriptor(
                    socketPath: socketPath,
                    token: token,
                    protocolVersion: "2025-06-18"
                )
            )
        } catch {
            close(fileDescriptor)
            unlink(socketPath)
            throw error
        }
        listenerFileDescriptor = fileDescriptor
        activeToken = token
        activeSocketPath = socketPath
        isRunning = true
        let handler = requestHandler
        acceptTask = Task.detached(priority: .userInitiated) {
            Self.acceptConnections(fileDescriptor: fileDescriptor, token: token, handler: handler)
        }
#else
        throw MCPTransportError.socketUnavailable
#endif
    }

    func stop() {
        guard isRunning else { return }
        acceptTask?.cancel()
        acceptTask = nil
#if canImport(Darwin)
        if listenerFileDescriptor >= 0 {
            shutdown(listenerFileDescriptor, SHUT_RDWR)
            close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }
#endif
        if let activeToken { try? endpointStore.remove(matchingToken: activeToken) }
        #if canImport(Darwin)
        if let activeSocketPath {
            unlink(activeSocketPath)
        }
        #endif
        activeToken = nil
        activeSocketPath = nil
        isRunning = false
    }

#if canImport(Darwin)
    private nonisolated static func acceptConnections(
        fileDescriptor: Int32,
        token: String,
        handler: RequestHandler?
    ) {
        guard let handler else { return }
        while true {
            let client = accept(fileDescriptor, nil, nil)
            guard client >= 0 else { return }
            Task.detached(priority: .userInitiated) {
                await Self.processConnection(client, token: token, handler: handler)
            }
        }
    }

    private nonisolated static func processConnection(
        _ client: Int32,
        token: String,
        handler: RequestHandler
    ) async {
        defer {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        while let line = readLine(from: client) {
            guard let data = line.data(using: .utf8),
                  let bridgeRequest = try? JSONDecoder().decode(MCPBridgeRequest.self, from: data)
            else { return }
            let response: MCPJSONRPCResponse
            if bridgeRequest.token != token {
                response = MCPJSONRPCResponse(
                    id: bridgeRequest.request.id,
                    error: MCPRPCError(code: .permissionDenied, message: "MCP session authorization failed.")
                )
            } else {
                response = await handler(bridgeRequest.request)
            }
            guard let responseData = try? JSONEncoder().encode(MCPBridgeResponse(response: response)) else {
                return
            }
            var payload = responseData
            payload.append(0x0A)
            guard writeAll(payload, to: client) else { return }
        }
    }

    private nonisolated static func readLine(from fileDescriptor: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        repeat {
            guard read(fileDescriptor, &byte, 1) == 1 else { return nil }
            data.append(byte)
            guard data.count <= JSONRPCLineFramer.maximumFrameBytes else { return nil }
        } while byte != 0x0A
        data.removeLast()
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = write(fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
#endif
}
