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
            "The file does not contain a valid watercolor painting. Open a different copy or restore it from a backup."
        case let .unsupportedSchema(version):
            "This painting uses newer version \(version) and cannot be opened here. Update Watercolor Studio, then try again."
        case let .validationFailed(error):
            switch error {
            case .layerLimitExceeded, .commandLimitExceeded, .documentByteLimitExceeded,
                 .totalStrokePointLimitExceeded:
                "This painting is too large to open safely. Open a smaller copy, or undo strokes in the app that created it and save again."
            default:
                "The file contains invalid painting data and was not opened. Open a different copy or restore it from a backup."
            }
        }
    }
}

public enum PaintingDocumentCodec {
    public static let maximumDocumentBytes = PaintingProject.maximumSerializedStorageBytes

    struct AdmissionLimits: Sendable {
        let maximumDocumentBytes: Int
        let maximumTotalStrokePointCount: Int

        static let production = Self(
            maximumDocumentBytes: PaintingDocumentCodec.maximumDocumentBytes,
            maximumTotalStrokePointCount: PaintingProject.maximumTotalStrokePointCount
        )
    }

    public static func encode(_ project: PaintingProject) throws -> Data {
        try encode(project, limits: .production)
    }

    static func encode(_ project: PaintingProject, limits: AdmissionLimits) throws -> Data {
        try validate(project, limits: limits)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(project)
        guard data.count <= limits.maximumDocumentBytes else {
            throw DocumentCodecError.validationFailed(.documentByteLimitExceeded(data.count))
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PaintingProject {
        try decode(data, limits: .production)
    }

    static func decode(_ data: Data, limits: AdmissionLimits) throws -> PaintingProject {
        guard data.count <= limits.maximumDocumentBytes else {
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
        if header.schemaVersion == 1 || header.schemaVersion == 2 {
            let validationProject = migrateLegacyProject(project, convertSRGBColor: false)
            try validate(validationProject, limits: limits)
            project = migrateLegacyProject(
                project,
                convertSRGBColor: header.schemaVersion == 1
            )
        }
        try validate(project, limits: limits)
        return project
    }

    private static func validate(_ project: PaintingProject, limits: AdmissionLimits) throws {
        guard project.schemaVersion <= PaintingProject.currentSchemaVersion else {
            throw DocumentCodecError.unsupportedSchema(project.schemaVersion)
        }

        do {
            try project.validate(limits: ProjectAdmissionLimits(
                maximumCommandCount: PaintingProject.maximumCommandCount,
                maximumTotalStrokePointCount: limits.maximumTotalStrokePointCount,
                maximumSerializedStorageBytes: limits.maximumDocumentBytes
            ))
        } catch let error as ProjectValidationError {
            throw DocumentCodecError.validationFailed(error)
        }
    }

    private static func migrateLegacyProject(
        _ legacyProject: PaintingProject,
        convertSRGBColor: Bool
    ) -> PaintingProject {
        var migrated = legacyProject
        migrated.schemaVersion = PaintingProject.currentSchemaVersion
        migrated.commands = legacyProject.commands.map { command in
            guard case var .stroke(stroke) = command else { return command }
            if convertSRGBColor {
                let legacyColor = stroke.brush.color
                stroke.brush.color = .fromSRGB(
                    red: legacyColor.red,
                    green: legacyColor.green,
                    blue: legacyColor.blue,
                    alpha: legacyColor.alpha
                )
            }
            stroke.brush.behaviorVersion = BrushSettings.legacyDynamics.behaviorVersion
            stroke.brush.spacing = BrushSettings.legacyDynamics.spacing
            stroke.brush.rotation = BrushSettings.legacyDynamics.rotation
            stroke.brush.bristleStrength = BrushSettings.legacyDynamics.bristleStrength
            stroke.brush.textureStrength = BrushSettings.legacyDynamics.textureStrength
            return .stroke(stroke)
        }
        return migrated
    }
}

private struct SchemaHeader: Decodable {
    let schemaVersion: Int
}
