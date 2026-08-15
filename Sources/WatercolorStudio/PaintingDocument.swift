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

    public init(project: PaintingProject = .newDefault()) {
        self.project = project
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw DocumentCodecError.malformedData
        }
        project = try PaintingDocumentCodec.decode(data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PaintingDocumentCodec.encode(project))
    }
}
