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
    public static let maximumDocumentBytes = 256 * 1024 * 1024

    public static func encode(_ project: PaintingProject) throws -> Data {
        try validate(project)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> PaintingProject {
        guard data.count <= maximumDocumentBytes else {
            throw DocumentCodecError.validationFailed(.documentByteLimitExceeded(data.count))
        }

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

        var project: PaintingProject
        do {
            project = try decoder.decode(PaintingProject.self, from: data)
        } catch {
            throw DocumentCodecError.malformedData
        }
        if header.schemaVersion == 1 {
            var validationProject = project
            validationProject.schemaVersion = PaintingProject.currentSchemaVersion
            try validate(validationProject)
            project = migrateVersionOneProject(project)
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

    private static func migrateVersionOneProject(_ legacyProject: PaintingProject) -> PaintingProject {
        var migrated = legacyProject
        migrated.schemaVersion = PaintingProject.currentSchemaVersion
        migrated.commands = legacyProject.commands.map { command in
            guard case var .stroke(stroke) = command else { return command }
            let legacyColor = stroke.brush.color
            stroke.brush.color = .fromSRGB(
                red: legacyColor.red,
                green: legacyColor.green,
                blue: legacyColor.blue,
                alpha: legacyColor.alpha
            )
            return .stroke(stroke)
        }
        return migrated
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}
