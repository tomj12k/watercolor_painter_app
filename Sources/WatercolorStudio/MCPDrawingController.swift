import Foundation
import WatercolorCore
import WatercolorMCP

@MainActor
final class MCPDrawingController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var sessionLabel: String?
    @Published private(set) var connectionError: String?

    private weak var model: StudioModel?
    private let bridge: MCPBridge
    private var activeStroke: StrokeCommand?

    init(model: StudioModel? = nil, bridge: MCPBridge = MCPBridge()) {
        self.model = model
        self.bridge = bridge
        bridge.requestHandler = { [weak self] request in
            guard let self else {
                return MCPJSONRPCResponse(
                    id: request.id,
                    error: MCPRPCError(code: .bridgeUnavailable, message: "Watercolor Studio is unavailable.")
                )
            }
            self.isConnected = true
            self.sessionLabel = "Local AI session"
            return await self.handle(request)
        }
    }

    func attach(model: StudioModel) {
        self.model = model
        // An open canvas is the explicit local surface that Claude controls.
        // Start its authenticated, loopback-only bridge here so the helper can
        // discover the app without requiring a separate toolbar click.
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            do {
                try bridge.start()
                isEnabled = true
                connectionError = nil
            } catch {
                isEnabled = false
                sessionLabel = nil
                connectionError = "AI Control could not start. Try again or check the local MCP host."
            }
        } else {
            stopSession()
            bridge.stop()
            isEnabled = false
            connectionError = nil
        }
    }

    func stopSession() {
        model?.cancelStrokePreview()
        activeStroke = nil
        isConnected = false
        sessionLabel = nil
    }

    func handle(_ request: MCPJSONRPCRequest) async -> MCPJSONRPCResponse {
        guard isEnabled else {
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPRPCError(code: .permissionDenied, message: "AI Control is turned off in Watercolor Studio.")
            )
        }
        switch request.method {
        case "tools/list":
            return MCPJSONRPCResponse(
                id: request.id,
                result: .object(["tools": .array(Self.toolCatalog.map(Self.toolJSON))])
            )
        case "tools/call":
            return await callTool(request)
        default:
            return MCPJSONRPCResponse(
                id: request.id,
                error: MCPRPCError(code: .methodNotFound, message: "This painting tool is not available yet.")
            )
        }
    }

    private func callTool(_ request: MCPJSONRPCRequest) async -> MCPJSONRPCResponse {
        guard let params = request.params,
              case let .object(values) = params,
              case let .string(name)? = values["name"]
        else { return failure(request, code: .invalidParams, message: "tools/call requires a tool name.") }
        let arguments: JSONValue = values["arguments"] ?? .object([:])
        guard let model else { return failure(request, code: .bridgeUnavailable, message: "No painting document is open.") }

        switch name {
        case "canvas_state":
            return success(request, canvasState(for: model))
        case "brush_catalog":
            return success(request, brushCatalog())
        case "layers":
            return success(request, layersState(for: model))
        case "layer_add":
            model.addLayer()
            return success(request, layersState(for: model))
        case "layer_duplicate":
            model.duplicateSelectedLayer()
            return success(request, layersState(for: model))
        case "layer_delete":
            model.deleteSelectedLayer()
            return success(request, layersState(for: model))
        case "layer_rename":
            let values = Self.object(from: arguments)
            guard let layerID = UUID(uuidString: Self.string(values["layerID"]) ?? ""),
                  let layerName = Self.string(values["name"]), !layerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return failure(request, code: .invalidParams, message: "layer_rename requires a layerID and name.") }
            model.renameLayer(id: layerID, to: layerName)
            return success(request, layersState(for: model))
        case "layer_visibility":
            let values = Self.object(from: arguments)
            guard let layerID = UUID(uuidString: Self.string(values["layerID"]) ?? ""),
                  case let .bool(isVisible)? = values["visible"]
            else { return failure(request, code: .invalidParams, message: "layer_visibility requires a layerID and visible flag.") }
            model.setLayerVisibility(id: layerID, isVisible: isVisible)
            return success(request, layersState(for: model))
        case "layer_select":
            guard let layerID = UUID(uuidString: Self.string(Self.object(from: arguments)["layerID"]) ?? ""),
                  model.project.layers.contains(where: { $0.id == layerID })
            else { return failure(request, code: .invalidParams, message: "layer_select requires an existing layerID.") }
            model.selectedLayerID = layerID
            return success(request, .object(["selectedLayerID": .string(layerID.uuidString)]))
        case "dry_layer":
            model.drySelectedLayer()
            return success(request, .object(["commandCount": .number(Double(model.project.commands.count))]))
        case "stroke_begin":
            return beginStroke(request, arguments: arguments, model: model)
        case "draw_stroke":
            return await drawStroke(request, arguments: arguments, model: model)
        case "stroke_append":
            return appendStroke(request, arguments: arguments, model: model)
        case "stroke_end":
            return await endStroke(request, model: model)
        case "stroke_cancel":
            model.cancelStrokePreview()
            activeStroke = nil
            return success(request, .object(["cancelled": .bool(true)]))
        case "undo":
            model.undo()
            return success(request, .object(["canUndo": .bool(model.capabilities.canUndo), "canRedo": .bool(model.capabilities.canRedo)]))
        case "redo":
            model.redo()
            return success(request, .object(["canUndo": .bool(model.capabilities.canUndo), "canRedo": .bool(model.capabilities.canRedo)]))
        case "export_png":
            let values = Self.object(from: arguments)
            guard let path = Self.string(values["path"]), path.hasSuffix(".png") else {
                return failure(request, code: .invalidParams, message: "export_png requires a .png path.")
            }
            await model.exportPNG(to: URL(fileURLWithPath: path).standardizedFileURL)
            if let error = model.error { return failure(request, code: .internalError, message: error.message) }
            return success(request, .object(["path": .string(URL(fileURLWithPath: path).standardizedFileURL.path), "exported": .bool(true)]))
        default:
            return failure(request, code: .methodNotFound, message: "Unknown painting tool \(name).")
        }
    }

    private func beginStroke(_ request: MCPJSONRPCRequest, arguments: JSONValue, model: StudioModel) -> MCPJSONRPCResponse {
        guard activeStroke == nil,
              let points = Self.points(from: arguments), !points.isEmpty
        else { return failure(request, code: .invalidParams, message: "stroke_begin requires at least one point and no active stroke.") }
        let values = Self.object(from: arguments)
        let tool = PaintTool(rawValue: Self.string(values["tool"]) ?? model.selectedTool.rawValue) ?? model.selectedTool
        let layerID = UUID(uuidString: Self.string(values["layerID"]) ?? "") ?? model.selectedLayerID
        let brush = Self.brush(from: values["brush"], base: model.brush)
        let stroke = StrokeCommand(layerID: layerID, tool: tool, brush: brush, points: points)
        guard model.beginStrokePreview(stroke) == .accepted else {
            return failure(request, code: .busy, message: "Watercolor Studio could not begin that stroke right now.")
        }
        activeStroke = stroke
        return success(request, .object(["strokeID": .string(stroke.id.uuidString), "accepted": .bool(true)]))
    }

    private func appendStroke(_ request: MCPJSONRPCRequest, arguments: JSONValue, model: StudioModel) -> MCPJSONRPCResponse {
        guard var stroke = activeStroke,
              let points = Self.points(from: arguments), !points.isEmpty
        else { return failure(request, code: .invalidParams, message: "stroke_append requires an active stroke and points.") }
        stroke.points.append(contentsOf: points)
        activeStroke = stroke
        model.appendStrokePreview(id: stroke.id, points: points)
        return success(request, .object(["strokeID": .string(stroke.id.uuidString), "pointCount": .number(Double(stroke.points.count))]))
    }

    private func drawStroke(_ request: MCPJSONRPCRequest, arguments: JSONValue, model: StudioModel) async -> MCPJSONRPCResponse {
        let begin = beginStroke(request, arguments: arguments, model: model)
        guard begin.error == nil else { return begin }
        return await endStroke(request, model: model)
    }

    private func endStroke(_ request: MCPJSONRPCRequest, model: StudioModel) async -> MCPJSONRPCResponse {
        guard let stroke = activeStroke else { return failure(request, code: .invalidParams, message: "There is no active stroke.") }
        await model.commitStrokePreview(stroke)
        activeStroke = nil
        if let error = model.error {
            return failure(request, code: .internalError, message: error.message)
        }
        return success(request, .object(["committed": .bool(true), "commandCount": .number(Double(model.project.commands.count))]))
    }

    private func canvasState(for model: StudioModel) -> JSONValue {
        .object([
            "canvas": .object(["width": .number(Double(model.project.canvas.width)), "height": .number(Double(model.project.canvas.height)), "paper": .string(model.project.paper.rawValue)]),
            "selectedLayerID": .string(model.selectedLayerID.uuidString),
            "commandCount": .number(Double(model.project.commands.count)),
            "canUndo": .bool(model.capabilities.canUndo),
            "canRedo": .bool(model.capabilities.canRedo)
        ])
    }

    private func layersState(for model: StudioModel) -> JSONValue {
        .array(model.project.layers.map { layer in
            .object(["id": .string(layer.id.uuidString), "name": .string(layer.name), "visible": .bool(layer.isVisible), "opacity": .number(layer.opacity)])
        })
    }

    private func brushCatalog() -> JSONValue {
        .object([
            "tools": .array(PaintTool.allCases.map { .string($0.rawValue) }),
            "shapes": .array(BrushShape.allCases.map { .string($0.rawValue) }),
            "hair": .array(BrushHair.allCases.map { .string($0.rawValue) }),
            "textures": .array(BrushTexture.allCases.map { .string($0.rawValue) }),
            "styles": .array(WatercolorStyle.allCases.map { .string($0.rawValue) })
        ])
    }

    private static func object(from value: JSONValue) -> [String: JSONValue] {
        guard case let .object(values) = value else { return [:] }
        return values
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(value) = value else { return nil }
        return value
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(value) = value, value.isFinite else { return nil }
        return value
    }

    private static func points(from value: JSONValue) -> [StrokePoint]? {
        guard case let .object(values) = value,
              case let .array(rawPoints)? = values["points"] else { return nil }
        return rawPoints.compactMap { raw in
            let point = object(from: raw)
            guard let x = number(point["x"]), let y = number(point["y"]) else { return nil }
            return StrokePoint(x: x, y: y, pressure: number(point["pressure"]) ?? 1, tiltX: number(point["tiltX"]) ?? 0, tiltY: number(point["tiltY"]) ?? 0, time: number(point["time"]) ?? 0)
        }
    }

    private static func brush(from value: JSONValue?, base: BrushSettings) -> BrushSettings {
        var brush = base
        let values = object(from: value ?? .object([:]))
        if let raw = string(values["shape"]), let parsed = BrushShape(rawValue: raw) { brush.shape = parsed }
        if let raw = string(values["hair"]), let parsed = BrushHair(rawValue: raw) { brush.hair = parsed }
        if let raw = string(values["texture"]), let parsed = BrushTexture(rawValue: raw) { brush.texture = parsed }
        if let raw = string(values["style"]), let parsed = WatercolorStyle(rawValue: raw) { brush.style = parsed }
        if let value = number(values["size"]) { brush.size = value }
        if let value = number(values["opacity"]) { brush.opacity = value }
        if let value = number(values["flow"]) { brush.flow = value }
        if let value = number(values["water"]) { brush.water = value }
        if let value = number(values["granulation"]) { brush.granulation = value }
        if let value = number(values["edgeBloom"]) { brush.edgeBloom = value }
        if let value = number(values["spacing"]) { brush.spacing = value }
        if let value = number(values["rotation"]) { brush.rotation = value }
        if let value = number(values["bristleStrength"]) { brush.bristleStrength = value }
        if let value = number(values["textureStrength"]) { brush.textureStrength = value }
        let colorValues = object(from: values["color"] ?? .null)
        if let red = number(colorValues["red"]), let green = number(colorValues["green"]), let blue = number(colorValues["blue"]) {
            brush.color = PaintColor(red: red, green: green, blue: blue, alpha: number(colorValues["alpha"]) ?? 1)
        }
        return brush
    }

    private func success(_ request: MCPJSONRPCRequest, _ result: JSONValue) -> MCPJSONRPCResponse {
        // MCP tool calls require human-readable content. Keep the same values
        // in structuredContent so an agent can reliably use IDs and limits in
        // its next call instead of scraping prose.
        let text = (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? "{}"
        return MCPJSONRPCResponse(
            id: request.id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": result
            ])
        )
    }

    private func failure(_ request: MCPJSONRPCRequest, code: MCPRPCError.Code, message: String) -> MCPJSONRPCResponse {
        MCPJSONRPCResponse(id: request.id, error: MCPRPCError(code: code, message: message))
    }

    private static let toolCatalog: [MCPTool] = [
        MCPTool(name: "canvas_state", description: "Read the canvas size, paper, selected layer, command count, and undo state.", inputSchema: noArgumentsSchema),
        MCPTool(name: "brush_catalog", description: "List every supported tool, shape, hair, texture, and watercolor style before painting.", inputSchema: noArgumentsSchema),
        MCPTool(name: "layers", description: "List painting layers with their IDs, names, visibility, and opacity.", inputSchema: noArgumentsSchema),
        MCPTool(name: "layer_add", description: "Add a new watercolor layer and select it.", inputSchema: noArgumentsSchema),
        MCPTool(name: "layer_duplicate", description: "Duplicate the selected watercolor layer.", inputSchema: noArgumentsSchema),
        MCPTool(name: "layer_delete", description: "Delete the selected watercolor layer when more than one layer exists.", inputSchema: noArgumentsSchema),
        MCPTool(name: "layer_rename", description: "Rename a layer by its ID.", inputSchema: objectSchema(["layerID": uuidSchema, "name": stringSchema], required: ["layerID", "name"])),
        MCPTool(name: "layer_visibility", description: "Show or hide a layer by its ID.", inputSchema: objectSchema(["layerID": uuidSchema, "visible": boolSchema], required: ["layerID", "visible"])),
        MCPTool(name: "layer_select", description: "Select an existing layer by ID before painting.", inputSchema: objectSchema(["layerID": uuidSchema], required: ["layerID"])),
        MCPTool(name: "dry_layer", description: "Dry the selected layer using the existing watercolor simulation.", inputSchema: noArgumentsSchema),
        MCPTool(name: "draw_stroke", description: "Paint one complete watercolor stroke in a single call. Use this for a simple line, contour, or filled-in picture stroke; it accepts the same points, tool, layerID, and brush options as stroke_begin.", inputSchema: strokeBeginSchema),
        MCPTool(name: "stroke_begin", description: "Start a watercolor stroke. Supply its first canvas-coordinate point and optional brush settings; then use stroke_append and stroke_end.", inputSchema: strokeBeginSchema),
        MCPTool(name: "stroke_append", description: "Append one or more canvas-coordinate points to the active watercolor stroke.", inputSchema: objectSchema(["points": pointsSchema], required: ["points"])),
        MCPTool(name: "stroke_end", description: "Commit the active watercolor stroke to the selected layer.", inputSchema: noArgumentsSchema),
        MCPTool(name: "stroke_cancel", description: "Cancel the active watercolor stroke without committing it.", inputSchema: noArgumentsSchema),
        MCPTool(name: "undo", description: "Undo the latest committed painting command.", inputSchema: noArgumentsSchema),
        MCPTool(name: "redo", description: "Redo the latest undone painting command.", inputSchema: noArgumentsSchema),
        MCPTool(name: "export_png", description: "Export the current canvas to an absolute .png file path.", inputSchema: objectSchema(["path": stringSchema], required: ["path"]))
    ]

    private static let noArgumentsSchema = objectSchema([:])
    private static let stringSchema: JSONValue = .object(["type": .string("string")])
    private static let uuidSchema: JSONValue = .object(["type": .string("string"), "format": .string("uuid")])
    private static let boolSchema: JSONValue = .object(["type": .string("boolean")])
    private static let numberSchema: JSONValue = .object(["type": .string("number")])
    private static let pointSchema = objectSchema([
        "x": numberSchema,
        "y": numberSchema,
        "pressure": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
        "tiltX": numberSchema,
        "tiltY": numberSchema,
        "time": numberSchema
    ], required: ["x", "y"])
    private static let pointsSchema: JSONValue = .object([
        "type": .string("array"),
        "minItems": .number(1),
        "items": pointSchema
    ])
    private static let colorSchema = objectSchema([
        "red": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
        "green": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
        "blue": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
        "alpha": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
    ], required: ["red", "green", "blue"])
    private static let brushSchema = objectSchema([
        "shape": enumSchema(BrushShape.allCases.map(\.rawValue)),
        "hair": enumSchema(BrushHair.allCases.map(\.rawValue)),
        "texture": enumSchema(BrushTexture.allCases.map(\.rawValue)),
        "style": enumSchema(WatercolorStyle.allCases.map(\.rawValue)),
        "color": colorSchema,
        "size": .object(["type": .string("number"), "minimum": .number(1), "maximum": .number(512)]),
        "opacity": unitIntervalSchema,
        "flow": unitIntervalSchema,
        "water": unitIntervalSchema,
        "granulation": unitIntervalSchema,
        "edgeBloom": unitIntervalSchema,
        "spacing": .object(["type": .string("number"), "minimum": .number(0.08), "maximum": .number(0.6)]),
        "rotation": .object(["type": .string("number"), "minimum": .number(-180), "maximum": .number(180)]),
        "bristleStrength": unitIntervalSchema,
        "textureStrength": unitIntervalSchema
    ])
    private static let unitIntervalSchema: JSONValue = .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
    private static let strokeBeginSchema = objectSchema([
        "points": pointsSchema,
        "tool": enumSchema(PaintTool.allCases.map(\.rawValue)),
        "layerID": uuidSchema,
        "brush": brushSchema
    ], required: ["points"])

    private static func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }

    private static func toolJSON(_ tool: MCPTool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema
        ])
    }
}
