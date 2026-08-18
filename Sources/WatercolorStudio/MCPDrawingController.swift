import Foundation
import WatercolorCore
import WatercolorMCP

@MainActor
final class MCPDrawingController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var sessionLabel: String?

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
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            do {
                try bridge.start()
                isEnabled = true
            } catch {
                isEnabled = false
                sessionLabel = nil
            }
        } else {
            stopSession()
            bridge.stop()
            isEnabled = false
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
        MCPJSONRPCResponse(id: request.id, result: result)
    }

    private func failure(_ request: MCPJSONRPCRequest, code: MCPRPCError.Code, message: String) -> MCPJSONRPCResponse {
        MCPJSONRPCResponse(id: request.id, error: MCPRPCError(code: code, message: message))
    }

    private static let toolCatalog: [MCPTool] = [
        MCPTool(name: "canvas_state", description: "Read the current watercolor canvas state.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "brush_catalog", description: "List watercolor tools and brush options.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layers", description: "List painting layers and their visibility.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_add", description: "Add a watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_duplicate", description: "Duplicate the selected watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_delete", description: "Delete the selected watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_rename", description: "Rename a watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_visibility", description: "Show or hide a watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "layer_select", description: "Select a watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "dry_layer", description: "Dry the selected watercolor layer.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_begin", description: "Begin an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_append", description: "Append points to an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_end", description: "Commit an AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "stroke_cancel", description: "Cancel the active AI watercolor stroke.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "undo", description: "Undo the latest painting command.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "redo", description: "Redo the latest painting command.", inputSchema: .object(["type": .string("object")])),
        MCPTool(name: "export_png", description: "Export the current painting as PNG.", inputSchema: .object(["type": .string("object")]))
    ]

    private static func toolJSON(_ tool: MCPTool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema
        ])
    }
}
