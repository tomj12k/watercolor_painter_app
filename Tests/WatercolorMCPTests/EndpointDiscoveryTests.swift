import Foundation
import Testing
@testable import WatercolorMCP

@Suite struct EndpointDiscoveryTests {
    @Test func descriptorRoundTripsAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watercolor-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        let store = MCPEndpointStore(directoryURL: directory)
        let descriptor = MCPEndpointDescriptor(
            socketPath: "/tmp/watercolor.sock",
            token: "token",
            protocolVersion: "2025-06-18"
        )
        try store.publish(descriptor)
        #expect(try store.read() == descriptor)
        try store.remove(matchingToken: "token")
        #expect(try store.read() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func wrongTokenCannotRemoveCurrentDescriptor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watercolor-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        let store = MCPEndpointStore(directoryURL: directory)
        let descriptor = MCPEndpointDescriptor(
            socketPath: "/tmp/watercolor.sock",
            token: "token",
            protocolVersion: "2025-06-18"
        )
        try store.publish(descriptor)
        try store.remove(matchingToken: "other")
        #expect(try store.read() == descriptor)
        try store.remove(matchingToken: "token")
        try? FileManager.default.removeItem(at: directory)
    }
}

