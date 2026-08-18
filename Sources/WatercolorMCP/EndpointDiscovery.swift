import Foundation

public struct MCPEndpointStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("WatercolorStudio", isDirectory: true)
    }

    public var descriptorURL: URL {
        directoryURL.appendingPathComponent("mcp-endpoint.json")
    }

    public func publish(_ descriptor: MCPEndpointDescriptor) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(descriptor)
        let temporaryURL = directoryURL.appendingPathComponent(".mcp-endpoint-\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if FileManager.default.fileExists(atPath: descriptorURL.path) {
            _ = try FileManager.default.replaceItemAt(descriptorURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: descriptorURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptorURL.path)
    }

    public func read() throws -> MCPEndpointDescriptor? {
        guard FileManager.default.fileExists(atPath: descriptorURL.path) else { return nil }
        return try JSONDecoder().decode(
            MCPEndpointDescriptor.self,
            from: Data(contentsOf: descriptorURL)
        )
    }

    public func remove(matchingToken token: String) throws {
        guard let descriptor = try read(), descriptor.token == token else { return }
        try FileManager.default.removeItem(at: descriptorURL)
    }
}

