import Foundation

public struct CanvasSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum PaperTexture: String, Codable, CaseIterable, Equatable, Sendable {
    case hotPress
    case coldPress
    case rough
    case handmade
    case canvas
}

public enum PaintTool: String, Codable, CaseIterable, Equatable, Sendable {
    case brush
    case water
    case eraser
    case smudge
    case smear
    case dry
}

public enum BrushShape: String, Codable, CaseIterable, Equatable, Sendable {
    case round
    case flat
    case filbert
    case fan
    case rigger
}

public enum BrushHair: String, Codable, CaseIterable, Equatable, Sendable {
    case sable
    case squirrel
    case synthetic
    case bristle
    case mop
}

public enum BrushTexture: String, Codable, CaseIterable, Equatable, Sendable {
    case smooth
    case granulating
    case dry
    case mottled
    case salt
}

public enum WatercolorStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case transparentWash
    case wetOnWet
    case dryBrush
    case glazing
    case bloom
}

public struct PaintColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = Self(red: 0, green: 0, blue: 0)
}

public struct BrushSettings: Codable, Equatable, Sendable {
    public var shape: BrushShape
    public var hair: BrushHair
    public var texture: BrushTexture
    public var style: WatercolorStyle
    public var color: PaintColor
    public var size: Double
    public var opacity: Double
    public var flow: Double
    public var water: Double
    public var granulation: Double
    public var edgeBloom: Double

    public init(
        shape: BrushShape,
        hair: BrushHair,
        texture: BrushTexture,
        style: WatercolorStyle,
        color: PaintColor,
        size: Double,
        opacity: Double,
        flow: Double,
        water: Double,
        granulation: Double,
        edgeBloom: Double
    ) {
        self.shape = shape
        self.hair = hair
        self.texture = texture
        self.style = style
        self.color = color
        self.size = size
        self.opacity = opacity
        self.flow = flow
        self.water = water
        self.granulation = granulation
        self.edgeBloom = edgeBloom
    }

    public static let `default` = Self(
        shape: .round,
        hair: .sable,
        texture: .smooth,
        style: .transparentWash,
        color: .black,
        size: 24,
        opacity: 0.35,
        flow: 0.4,
        water: 0.6,
        granulation: 0.2,
        edgeBloom: 0.15
    )
}

public struct StrokePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var tiltX: Double
    public var tiltY: Double
    public var time: Double

    public init(x: Double, y: Double, pressure: Double, tiltX: Double, tiltY: Double, time: Double) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.time = time
    }
}

public struct StrokeCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var layerID: UUID
    public var tool: PaintTool
    public var brush: BrushSettings
    public var points: [StrokePoint]

    public init(
        id: UUID = UUID(),
        layerID: UUID,
        tool: PaintTool,
        brush: BrushSettings,
        points: [StrokePoint]
    ) {
        self.id = id
        self.layerID = layerID
        self.tool = tool
        self.brush = brush
        self.points = points
    }
}

public struct LayerCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var layerID: UUID

    public init(id: UUID = UUID(), layerID: UUID) {
        self.id = id
        self.layerID = layerID
    }
}

public struct MergeDownCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceLayerID: UUID
    public var destinationLayerID: UUID

    public init(id: UUID = UUID(), sourceLayerID: UUID, destinationLayerID: UUID) {
        self.id = id
        self.sourceLayerID = sourceLayerID
        self.destinationLayerID = destinationLayerID
    }
}

public struct DryLayerCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var layerID: UUID
    public var steps: Int

    public init(id: UUID = UUID(), layerID: UUID, steps: Int) {
        self.id = id
        self.layerID = layerID
        self.steps = steps
    }
}

public enum PaintingCommand: Codable, Equatable, Sendable, Identifiable {
    case stroke(StrokeCommand)
    case clearLayer(LayerCommand)
    case mergeDown(MergeDownCommand)
    case dryLayer(DryLayerCommand)

    public var id: UUID {
        switch self {
        case let .stroke(command): command.id
        case let .clearLayer(command): command.id
        case let .mergeDown(command): command.id
        case let .dryLayer(command): command.id
        }
    }
}

public struct PaintLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var opacity: Double

    public init(id: UUID = UUID(), name: String, isVisible: Bool = true, opacity: Double = 1) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
    }
}

public enum ProjectValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidCanvasSize(CanvasSize)
    case missingLayers
    case layerLimitExceeded(Int)
    case duplicateLayerIdentifier(UUID)
}

public struct PaintingProject: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumCanvasDimension = 256
    public static let maximumCanvasDimension = 4096
    public static let maximumLayerCount = 12

    public var schemaVersion: Int
    public var canvas: CanvasSize
    public var paper: PaperTexture
    public var layers: [PaintLayer]
    public var commands: [PaintingCommand]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        canvas: CanvasSize,
        paper: PaperTexture,
        layers: [PaintLayer],
        commands: [PaintingCommand] = []
    ) {
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.paper = paper
        self.layers = layers
        self.commands = commands
    }

    public static func newDefault() -> Self {
        Self(
            canvas: CanvasSize(width: 1600, height: 1200),
            paper: .coldPress,
            layers: [PaintLayer(name: "Layer 1")]
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProjectValidationError.unsupportedSchema(schemaVersion)
        }

        guard
            (Self.minimumCanvasDimension...Self.maximumCanvasDimension).contains(canvas.width),
            (Self.minimumCanvasDimension...Self.maximumCanvasDimension).contains(canvas.height)
        else {
            throw ProjectValidationError.invalidCanvasSize(canvas)
        }

        guard !layers.isEmpty else {
            throw ProjectValidationError.missingLayers
        }

        guard layers.count <= Self.maximumLayerCount else {
            throw ProjectValidationError.layerLimitExceeded(layers.count)
        }

        var identifiers = Set<UUID>()
        for layer in layers where !identifiers.insert(layer.id).inserted {
            throw ProjectValidationError.duplicateLayerIdentifier(layer.id)
        }
    }
}
