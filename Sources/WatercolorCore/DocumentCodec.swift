import Foundation

public enum DocumentCodecError: Error, Equatable, Sendable {
    case malformedData
    case unsupportedSchema(Int)
    case validationFailed(ProjectValidationError)
}

extension DocumentCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedData:
            "The file does not contain a valid watercolor project."
        case let .unsupportedSchema(version):
            "This project uses newer schema version \(version) and cannot be opened by this version of Watercolor Studio."
        case let .validationFailed(error):
            "The watercolor project is invalid: \(String(describing: error))."
        }
    }
}

public enum PaintingDocumentCodec {
    public static func encode(_ project: PaintingProject) throws -> Data {
        try validate(project)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> PaintingProject {
        let decoder = JSONDecoder()
        let header: SchemaHeader
        do {
            header = try decoder.decode(SchemaHeader.self, from: data)
        } catch {
            throw DocumentCodecError.malformedData
        }

        guard header.schemaVersion <= PaintingProject.currentSchemaVersion else {
            throw DocumentCodecError.unsupportedSchema(header.schemaVersion)
        }

        let project: PaintingProject
        do {
            project = try decoder.decode(PaintingProject.self, from: data)
        } catch {
            throw DocumentCodecError.malformedData
        }
        try validate(project)
        return project
    }

    private static func validate(_ project: PaintingProject) throws {
        guard project.schemaVersion <= PaintingProject.currentSchemaVersion else {
            throw DocumentCodecError.unsupportedSchema(project.schemaVersion)
        }

        do {
            try project.validate()
        } catch let error as ProjectValidationError {
            throw DocumentCodecError.validationFailed(error)
        }
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}
