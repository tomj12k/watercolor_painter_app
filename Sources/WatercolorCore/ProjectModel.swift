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

    public static func fromSRGB(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) -> Self {
        Self(
            red: linearComponent(fromSRGB: red),
            green: linearComponent(fromSRGB: green),
            blue: linearComponent(fromSRGB: blue),
            alpha: alpha
        )
    }

    public func convertedToSRGB() -> Self {
        Self(
            red: Self.sRGBComponent(fromLinear: red),
            green: Self.sRGBComponent(fromLinear: green),
            blue: Self.sRGBComponent(fromLinear: blue),
            alpha: alpha
        )
    }

    public func mixedLinearly(with other: Self, ratio: Double) -> Self {
        let ratio = min(max(ratio, 0), 1)
        return Self(
            red: red + (other.red - red) * ratio,
            green: green + (other.green - green) * ratio,
            blue: blue + (other.blue - blue) * ratio,
            alpha: alpha + (other.alpha - alpha) * ratio
        )
    }

    public static func linearComponent(fromSRGB component: Double) -> Double {
        let component = min(max(component, 0), 1)
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    public static func sRGBComponent(fromLinear component: Double) -> Double {
        let component = min(max(component, 0), 1)
        if component <= 0.003_130_8 {
            return component * 12.92
        }
        return 1.055 * pow(component, 1 / 2.4) - 0.055
    }
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
    public var sourceIsVisible: Bool
    public var sourceOpacity: Double
    public var destinationIsVisible: Bool
    public var destinationOpacity: Double

    public init(
        id: UUID = UUID(),
        sourceLayerID: UUID,
        destinationLayerID: UUID,
        sourceIsVisible: Bool = true,
        sourceOpacity: Double = 1,
        destinationIsVisible: Bool = true,
        destinationOpacity: Double = 1
    ) {
        self.id = id
        self.sourceLayerID = sourceLayerID
        self.destinationLayerID = destinationLayerID
        self.sourceIsVisible = sourceIsVisible
        self.sourceOpacity = sourceOpacity
        self.destinationIsVisible = destinationIsVisible
        self.destinationOpacity = destinationOpacity
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceLayerID
        case destinationLayerID
        case sourceIsVisible
        case sourceOpacity
        case destinationIsVisible
        case destinationOpacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceLayerID = try container.decode(UUID.self, forKey: .sourceLayerID)
        destinationLayerID = try container.decode(UUID.self, forKey: .destinationLayerID)
        sourceIsVisible = try container.decodeIfPresent(Bool.self, forKey: .sourceIsVisible) ?? true
        sourceOpacity = try container.decodeIfPresent(Double.self, forKey: .sourceOpacity) ?? 1
        destinationIsVisible = try container.decodeIfPresent(Bool.self, forKey: .destinationIsVisible) ?? true
        destinationOpacity = try container.decodeIfPresent(Double.self, forKey: .destinationOpacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceLayerID, forKey: .sourceLayerID)
        try container.encode(destinationLayerID, forKey: .destinationLayerID)
        try container.encode(sourceIsVisible, forKey: .sourceIsVisible)
        try container.encode(sourceOpacity, forKey: .sourceOpacity)
        try container.encode(destinationIsVisible, forKey: .destinationIsVisible)
        try container.encode(destinationOpacity, forKey: .destinationOpacity)
    }
}

public struct DuplicateLayerCommand: Codable, Equatable, Sendable, Identifiable {
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
    case duplicateLayer(DuplicateLayerCommand)
    case mergeDown(MergeDownCommand)
    case dryLayer(DryLayerCommand)

    public var id: UUID {
        switch self {
        case let .stroke(command): command.id
        case let .clearLayer(command): command.id
        case let .duplicateLayer(command): command.id
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
    case invalidLayerIdentifier(UUID)
    case invalidLayerName(UUID)
    case invalidLayerOpacity(UUID, Double)
    case commandLimitExceeded(Int)
    case duplicateCommandIdentifier(UUID)
    case invalidCommandIdentifier(UUID)
    case invalidCommandRelationship(UUID)
    case invalidColorComponent(UUID)
    case invalidBrushSize(UUID, Double)
    case invalidBrushParameter(UUID)
    case invalidStrokePointCount(UUID, Int)
    case invalidStrokePoint(UUID, Int)
    case nonMonotonicStrokeTime(UUID, Int)
    case invalidDryStepCount(UUID, Int)
}

public struct PaintingProject: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumCanvasDimension = 256
    public static let maximumCanvasDimension = 4096
    public static let maximumLayerCount = 12
    public static let maximumCommandCount = 100_000
    public static let maximumStrokePointCount = 65_536
    public static let maximumDryStepCount = 4_096
    public static let brushSizeRange = 1.0...300.0

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
        try validate(requireMinimumCanvasDimension: true)
    }

    /// Renderer entry points also accept smaller canvases for thumbnails and tests, while
    /// preserving every upper bound and nested-data safety invariant used by documents.
    public func validateForRendering() throws {
        try validate(requireMinimumCanvasDimension: false)
    }

    public func validateForRendering(_ stroke: StrokeCommand) throws {
        guard stroke.layerID != Self.zeroIdentifier else {
            throw ProjectValidationError.invalidCommandRelationship(stroke.id)
        }
        try validate(stroke)
    }

    private func validate(requireMinimumCanvasDimension: Bool) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProjectValidationError.unsupportedSchema(schemaVersion)
        }

        let minimumDimension = requireMinimumCanvasDimension ? Self.minimumCanvasDimension : 1
        guard
            (minimumDimension...Self.maximumCanvasDimension).contains(canvas.width),
            (minimumDimension...Self.maximumCanvasDimension).contains(canvas.height)
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
        for layer in layers {
            guard layer.id != Self.zeroIdentifier else {
                throw ProjectValidationError.invalidLayerIdentifier(layer.id)
            }
            guard identifiers.insert(layer.id).inserted else {
                throw ProjectValidationError.duplicateLayerIdentifier(layer.id)
            }
            guard !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.count <= 256
            else {
                throw ProjectValidationError.invalidLayerName(layer.id)
            }
            guard Self.unitRangeContains(layer.opacity) else {
                throw ProjectValidationError.invalidLayerOpacity(layer.id, layer.opacity)
            }
        }

        guard commands.count <= Self.maximumCommandCount else {
            throw ProjectValidationError.commandLimitExceeded(commands.count)
        }

        var commandIdentifiers = Set<UUID>()
        var duplicateDestinations = Set<UUID>()
        for command in commands {
            guard command.id != Self.zeroIdentifier else {
                throw ProjectValidationError.invalidCommandIdentifier(command.id)
            }
            guard commandIdentifiers.insert(command.id).inserted else {
                throw ProjectValidationError.duplicateCommandIdentifier(command.id)
            }

            switch command {
            case let .stroke(stroke):
                guard stroke.layerID != Self.zeroIdentifier else {
                    throw ProjectValidationError.invalidCommandRelationship(stroke.id)
                }
                try validate(stroke)
            case let .clearLayer(clear):
                guard clear.layerID != Self.zeroIdentifier else {
                    throw ProjectValidationError.invalidCommandRelationship(clear.id)
                }
            case let .duplicateLayer(duplicate):
                guard duplicate.sourceLayerID != Self.zeroIdentifier,
                      duplicate.destinationLayerID != Self.zeroIdentifier,
                      duplicate.sourceLayerID != duplicate.destinationLayerID,
                      duplicateDestinations.insert(duplicate.destinationLayerID).inserted
                else {
                    throw ProjectValidationError.invalidCommandRelationship(duplicate.id)
                }
            case let .mergeDown(merge):
                guard merge.sourceLayerID != Self.zeroIdentifier,
                      merge.destinationLayerID != Self.zeroIdentifier,
                      merge.sourceLayerID != merge.destinationLayerID,
                      Self.unitRangeContains(merge.sourceOpacity),
                      Self.unitRangeContains(merge.destinationOpacity)
                else {
                    throw ProjectValidationError.invalidCommandRelationship(merge.id)
                }
            case let .dryLayer(dry):
                guard dry.layerID != Self.zeroIdentifier else {
                    throw ProjectValidationError.invalidCommandRelationship(dry.id)
                }
                guard (0...Self.maximumDryStepCount).contains(dry.steps) else {
                    throw ProjectValidationError.invalidDryStepCount(dry.id, dry.steps)
                }
            }
        }
    }

    private func validate(_ stroke: StrokeCommand) throws {
        let brush = stroke.brush
        guard Self.brushSizeRange.contains(brush.size), brush.size.isFinite else {
            throw ProjectValidationError.invalidBrushSize(stroke.id, brush.size)
        }
        guard [brush.opacity, brush.flow, brush.water, brush.granulation, brush.edgeBloom]
            .allSatisfy(Self.unitRangeContains)
        else {
            throw ProjectValidationError.invalidBrushParameter(stroke.id)
        }
        guard [brush.color.red, brush.color.green, brush.color.blue, brush.color.alpha]
            .allSatisfy(Self.unitRangeContains)
        else {
            throw ProjectValidationError.invalidColorComponent(stroke.id)
        }
        guard (1...Self.maximumStrokePointCount).contains(stroke.points.count) else {
            throw ProjectValidationError.invalidStrokePointCount(stroke.id, stroke.points.count)
        }

        var previousTime = -Double.infinity
        for (index, point) in stroke.points.enumerated() {
            guard point.x.isFinite,
                  point.y.isFinite,
                  point.pressure.isFinite,
                  point.tiltX.isFinite,
                  point.tiltY.isFinite,
                  point.time.isFinite,
                  (0...Double(canvas.width)).contains(point.x),
                  (0...Double(canvas.height)).contains(point.y),
                  Self.unitRangeContains(point.pressure),
                  (-1...1).contains(point.tiltX),
                  (-1...1).contains(point.tiltY)
            else {
                throw ProjectValidationError.invalidStrokePoint(stroke.id, index)
            }
            guard point.time >= previousTime else {
                throw ProjectValidationError.nonMonotonicStrokeTime(stroke.id, index)
            }
            previousTime = point.time
        }
    }

    private static func unitRangeContains(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static let zeroIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
