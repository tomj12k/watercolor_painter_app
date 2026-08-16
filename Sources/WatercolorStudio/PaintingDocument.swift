import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WatercolorCore

public extension UTType {
    static let watercolorPainting = UTType(
        exportedAs: "com.watercolorstudio.painting",
        conformingTo: .json
    )
}

public struct PaintingDocument: FileDocument {
    public static let filenameExtension = "watercolor"
    public static let readableContentTypes: [UTType] = [.watercolorPainting]

    public var project: PaintingProject
    var needsInitialConfiguration: Bool

    public init() {
        project = .newDefault()
        needsInitialConfiguration = true
    }

    public init(project: PaintingProject) {
        self.project = project
        needsInitialConfiguration = false
    }

    public init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    init(
        fileWrapper: FileWrapper,
        decode: (Data) throws -> PaintingProject = PaintingDocumentCodec.decode
    ) throws {
        guard fileWrapper.isRegularFile,
              let data = fileWrapper.regularFileContents
        else {
            throw DocumentCodecError.malformedData
        }
        project = try decode(data)
        needsInitialConfiguration = false
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PaintingDocumentCodec.encode(project))
    }
}
