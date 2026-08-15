import CoreGraphics
import Foundation
import Metal
import MetalKit
import WatercolorCore

public enum RendererError: Error, Equatable, Sendable {
    case metalUnavailable
    case shaderCompilation(String)
    case allocation(String)
    case unknownLayer(UUID)
    case invalidMetadataChange
    case readback(String)
}

extension RendererError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "Metal is unavailable on this Mac."
        case let .shaderCompilation(message):
            "The watercolor shaders could not be compiled: \(message)"
        case let .allocation(resource):
            "The watercolor renderer could not allocate \(resource)."
        case let .unknownLayer(identifier):
            "The watercolor renderer does not contain layer \(identifier.uuidString)."
        case .invalidMetadataChange:
            "This painting change requires a structural renderer replay."
        case let .readback(message):
            "The rendered image could not be read back: \(message)"
        }
    }
}

@MainActor
public final class WatercolorRenderer: NSObject, MTKViewDelegate {
    private static let layerCapacity = PaintingProject.maximumLayerCount
    private static let simulationStepsPerStroke = 2
    private static let allLayers = UInt32.max

    public private(set) var project: PaintingProject
    public private(set) var viewportSize: CGSize
    public private(set) var canvasWetness: Double

    /// The canvas-sized, top-left-oriented texture consumed by the MTKView display pass.
    public var renderedTexture: MTLTexture { compositeTexture }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineResources: RendererPipelineResources
    private var stampPipeline: MTLComputePipelineState { pipelineResources.stamp }
    private var simulationPipeline: MTLComputePipelineState { pipelineResources.simulation }
    private var clearPipeline: MTLComputePipelineState { pipelineResources.clear }
    private var copyLayerPipeline: MTLComputePipelineState { pipelineResources.copyLayer }
    private var mergePipeline: MTLComputePipelineState { pipelineResources.merge }
    private var compositePipeline: MTLComputePipelineState { pipelineResources.composite }
    private var wetnessTileMaximumPipeline: MTLComputePipelineState { pipelineResources.wetnessTileMaximum }
    private var wetnessFinalMaximumPipeline: MTLComputePipelineState { pipelineResources.wetnessFinalMaximum }
    private var displayPipeline: MTLRenderPipelineState { pipelineResources.display }
    private let layerMetadataBuffer: MTLBuffer
    private var wetnessTileMaximumBuffer: MTLBuffer
    private let wetnessMaximumBuffer: MTLBuffer

    private var pigmentTextures: [MTLTexture]
    private var wetnessTextures: [MTLTexture]
    private var compositeTexture: MTLTexture
    private var transactionCompositeTexture: MTLTexture
    private var frontTextureIndex = 0
    private var layerSlices: [UUID: Int] = [:]
    private var layerOpacityPreviews: [UUID: Double] = [:]
    private var lastCommandBuffer: MTLCommandBuffer?
    private let commandBufferError: (MTLCommandBuffer) -> Error?
    private var displayZoom: CGFloat = 1
    private var displayPan: CGSize = .zero
    #if DEBUG
    private var replayCount = 0
    #endif

    public convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            commandBufferError: { $0.error }
        )
    }

    #if DEBUG
    convenience init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        debugCommandBufferError: @escaping (MTLCommandBuffer) -> Error?
    ) throws {
        try self.init(
            project: project,
            device: requestedDevice,
            pipelineResources: nil,
            commandBufferError: debugCommandBufferError
        )
    }
    #endif

    private init(
        project: PaintingProject,
        device requestedDevice: MTLDevice?,
        pipelineResources sharedPipelineResources: RendererPipelineResources?,
        commandBufferError: @escaping (MTLCommandBuffer) -> Error?
    ) throws {
        guard let requestedDevice else {
            throw RendererError.metalUnavailable
        }
        guard let commandQueue = requestedDevice.makeCommandQueue() else {
            throw RendererError.allocation("a Metal command queue")
        }

        self.device = requestedDevice
        self.commandQueue = commandQueue
        let resolvedPipelineResources = try sharedPipelineResources
            ?? RendererPipelineResources(device: requestedDevice)
        pipelineResources = resolvedPipelineResources

        guard let layerMetadataBuffer = requestedDevice.makeBuffer(
            length: Self.layerCapacity * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.allocation("layer metadata")
        }
        self.layerMetadataBuffer = layerMetadataBuffer
        guard let wetnessMaximumBuffer = requestedDevice.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.allocation("a canvas wetness measurement")
        }
        self.wetnessMaximumBuffer = wetnessMaximumBuffer
        wetnessMaximumBuffer.label = "Canvas wetness maximum"
        let wetnessTileCount = Self.wetnessTileCount(
            width: project.canvas.width,
            height: project.canvas.height,
            threadsPerThreadgroup: Self.wetnessTileThreadgroupSize(for: resolvedPipelineResources.wetnessTileMaximum)
        )
        wetnessTileMaximumBuffer = try Self.makeWetnessTileMaximumBuffer(
            device: requestedDevice,
            length: wetnessTileCount * MemoryLayout<UInt32>.stride
        )
        self.commandBufferError = commandBufferError

        let textures = try Self.makeTextures(
            device: requestedDevice,
            width: project.canvas.width,
            height: project.canvas.height
        )
        pigmentTextures = textures.pigment
        wetnessTextures = textures.wetness
        compositeTexture = textures.composite
        transactionCompositeTexture = textures.transactionComposite
        self.project = project
        viewportSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        canvasWetness = 0

        super.init()
        try replay(project: project)
    }

    public func resizeViewport(_ size: CGSize) {
        viewportSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    public func configureDisplay(zoom: CGFloat, pan: CGSize) {
        displayZoom = zoom
        displayPan = pan
    }

    public func makeCandidate(project: PaintingProject) throws -> WatercolorRenderer {
        try WatercolorRenderer(
            project: project,
            device: device,
            pipelineResources: pipelineResources,
            commandBufferError: commandBufferError
        )
    }

    public func render(stroke: StrokeCommand) throws {
        try render(stroke: stroke, waitUntilCompleted: false)
    }

    public func renderAndWait(stroke: StrokeCommand) throws {
        try render(stroke: stroke, waitUntilCompleted: true)
    }

    private func render(stroke: StrokeCommand, waitUntilCompleted: Bool) throws {
        guard project.layers.contains(where: { $0.id == stroke.layerID }),
              let slice = layerSlices[stroke.layerID]
        else {
            throw RendererError.unknownLayer(stroke.layerID)
        }

        let commandBuffer = try makeCommandBuffer(label: "Watercolor stroke")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a stroke command encoder")
        }
        encoder.label = "Watercolor stroke and simulation"
        encode(stroke: stroke, slice: slice, with: encoder)
        encodeSimulation(steps: Self.simulationStepsPerStroke, targetSlice: Self.allLayers, with: encoder)
        encodeComposite(with: encoder)
        if waitUntilCompleted {
            prepareCanvasWetnessMeasurement()
            encodeCanvasWetnessMeasurement(with: encoder)
        }
        encoder.endEncoding()
        try submit(commandBuffer, wait: waitUntilCompleted)
        if waitUntilCompleted {
            readCanvasWetnessMeasurement()
        }
    }

    public func replay(project newProject: PaintingProject) throws {
        #if DEBUG
        replayCount += 1
        #endif
        let replayPlan = try Self.makeReplayPlan(for: newProject)
        try synchronizeGPU(readback: false)
        let replacementTextures: (
            pigment: [MTLTexture],
            wetness: [MTLTexture],
            composite: MTLTexture,
            transactionComposite: MTLTexture
        )?
        if newProject.canvas.width != compositeTexture.width || newProject.canvas.height != compositeTexture.height {
            replacementTextures = try Self.makeTextures(
                device: device,
                width: newProject.canvas.width,
                height: newProject.canvas.height
            )
        } else {
            replacementTextures = nil
        }
        let replacementWetnessTileMaximumBuffer: MTLBuffer?
        let requiredWetnessTileLength = Self.wetnessTileCount(
            width: newProject.canvas.width,
            height: newProject.canvas.height,
            threadsPerThreadgroup: wetnessTileThreadgroupSize
        ) * MemoryLayout<UInt32>.stride
        if requiredWetnessTileLength > wetnessTileMaximumBuffer.length {
            replacementWetnessTileMaximumBuffer = try Self.makeWetnessTileMaximumBuffer(
                device: device,
                length: requiredWetnessTileLength
            )
        } else {
            replacementWetnessTileMaximumBuffer = nil
        }

        let commandBuffer = try makeCommandBuffer(label: "Watercolor replay")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a replay command encoder")
        }
        encoder.label = "Deterministic watercolor replay"

        if let replacementTextures {
            pigmentTextures = replacementTextures.pigment
            wetnessTextures = replacementTextures.wetness
            compositeTexture = replacementTextures.composite
            transactionCompositeTexture = replacementTextures.transactionComposite
            viewportSize = CGSize(width: newProject.canvas.width, height: newProject.canvas.height)
        }
        if let replacementWetnessTileMaximumBuffer {
            wetnessTileMaximumBuffer = replacementWetnessTileMaximumBuffer
        }
        project = newProject
        layerSlices = replayPlan.finalLayerSlices
        layerOpacityPreviews.removeAll()
        frontTextureIndex = 0
        updateLayerMetadata()

        encodeClear(targetSlice: Self.allLayers, texturesAt: 0, with: encoder)
        encodeClear(targetSlice: Self.allLayers, texturesAt: 1, with: encoder)

        for action in replayPlan.actions {
            switch action {
            case let .stroke(stroke, slice):
                encode(stroke: stroke, slice: slice, with: encoder)
                encodeSimulation(
                    steps: Self.simulationStepsPerStroke,
                    targetSlice: Self.allLayers,
                    with: encoder
                )
            case .simulateDiscardedStroke:
                encodeSimulation(
                    steps: Self.simulationStepsPerStroke,
                    targetSlice: Self.allLayers,
                    with: encoder
                )
            case let .clear(slice):
                encodeClear(targetSlice: UInt32(slice), texturesAt: frontTextureIndex, with: encoder)
            case let .duplicate(source, destination):
                encodeCopy(source: source, destination: destination, with: encoder)
            case let .merge(source, destination):
                encodeMerge(source: source, destination: destination, with: encoder)
            case let .dry(slice, steps):
                encodeSimulation(steps: steps, targetSlice: UInt32(slice), with: encoder)
            }
        }

        encodeComposite(with: encoder)
        prepareCanvasWetnessMeasurement()
        encodeCanvasWetnessMeasurement(with: encoder)
        encoder.endEncoding()
        try submit(commandBuffer, wait: true)
        readCanvasWetnessMeasurement()
    }

    public func applyMetadata(project updatedProject: PaintingProject) throws {
        let currentIdentifiers = Set(project.layers.map(\.id))
        let updatedIdentifiers = Set(updatedProject.layers.map(\.id))
        guard updatedProject.canvas == project.canvas,
              updatedProject.commands == project.commands,
              currentIdentifiers == updatedIdentifiers,
              updatedProject.layers.count == project.layers.count
        else {
            throw RendererError.invalidMetadataChange
        }

        try prepareCompositeTransaction(
            project: updatedProject,
            opacityPreviews: [:],
            label: "Apply layer metadata"
        )
        project = updatedProject
        layerOpacityPreviews.removeAll()
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    public func dry(layerID: UUID, steps: Int) throws {
        guard project.layers.contains(where: { $0.id == layerID }),
              let slice = layerSlices[layerID]
        else {
            throw RendererError.unknownLayer(layerID)
        }

        let commandBuffer = try makeCommandBuffer(label: "Dry watercolor layer")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.allocation("a drying command encoder")
        }
        encodeSimulation(steps: max(0, steps), targetSlice: UInt32(slice), with: encoder)
        encodeComposite(with: encoder)
        prepareCanvasWetnessMeasurement()
        encodeCanvasWetnessMeasurement(with: encoder)
        encoder.endEncoding()
        try submit(commandBuffer, wait: true)
        readCanvasWetnessMeasurement()
    }

    public func previewLayerOpacity(id: UUID, opacity: Double) throws {
        guard project.layers.contains(where: { $0.id == id }) else {
            throw RendererError.unknownLayer(id)
        }
        guard opacity.isFinite else { return }
        var candidatePreviews = layerOpacityPreviews
        candidatePreviews[id] = min(max(opacity, 0), 1)
        try prepareCompositeTransaction(
            project: project,
            opacityPreviews: candidatePreviews,
            label: "Preview layer metadata"
        )
        layerOpacityPreviews = candidatePreviews
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    public func clearLayerOpacityPreview(id: UUID) throws {
        guard project.layers.contains(where: { $0.id == id }) else {
            throw RendererError.unknownLayer(id)
        }
        guard layerOpacityPreviews[id] != nil else { return }
        var candidatePreviews = layerOpacityPreviews
        candidatePreviews.removeValue(forKey: id)
        try prepareCompositeTransaction(
            project: project,
            opacityPreviews: candidatePreviews,
            label: "Preview layer metadata"
        )
        layerOpacityPreviews = candidatePreviews
        swap(&compositeTexture, &transactionCompositeTexture)
    }

    public func draw(in view: MTKView) {
        guard view.colorPixelFormat == .bgra8Unorm,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        commandBuffer.label = "Display watercolor composite"
        encoder.label = "Watercolor display pass"
        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(compositeTexture, index: 0)
        let paperRect = CanvasTransform(
            viewSize: view.bounds.size,
            canvasSize: CGSize(width: compositeTexture.width, height: compositeTexture.height),
            zoom: displayZoom,
            pan: displayPan
        ).normalizedPaperRect
        var displayParameters = SIMD4<Float>(
            Float(paperRect.minX),
            Float(paperRect.minY),
            Float(paperRect.width),
            Float(paperRect.height)
        )
        encoder.setFragmentBytes(
            &displayParameters,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resizeViewport(size)
    }

    public func makeCGImage() throws -> CGImage {
        try synchronizeGPU(readback: true)
        let width = compositeTexture.width
        let height = compositeTexture.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            compositeTexture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw RendererError.readback("Core Graphics rejected the pixel data provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw RendererError.readback("Core Graphics could not create the image")
        }
        return image
    }

    private static func relevantLayerIDs(in project: PaintingProject) throws -> Set<UUID> {
        guard !project.layers.isEmpty, project.layers.count <= Self.layerCapacity else {
            throw RendererError.allocation("metadata for \(project.layers.count) layers")
        }
        let currentIdentifiers = project.layers.map(\.id)
        guard Set(currentIdentifiers).count == currentIdentifiers.count else {
            throw RendererError.allocation("metadata for duplicate layer identifiers")
        }

        var relevant = Set(currentIdentifiers)
        for command in project.commands.reversed() {
            switch command {
            case let .duplicateLayer(duplicate) where relevant.contains(duplicate.destinationLayerID):
                relevant.insert(duplicate.sourceLayerID)
            case let .mergeDown(merge) where relevant.contains(merge.destinationLayerID):
                relevant.insert(merge.sourceLayerID)
            default:
                break
            }
        }
        return relevant
    }

    private static func makeReplayPlan(for project: PaintingProject) throws -> ReplayPlan {
        let relevantLayerIDs = try relevantLayerIDs(in: project)
        let currentLayerIDs = Set(project.layers.map(\.id))
        let releasesByCommand = historicalLayerReleases(
            in: project,
            relevantLayerIDs: relevantLayerIDs,
            currentLayerIDs: currentLayerIDs
        )
        var layerSlices: [UUID: Int] = [:]
        var freeSlices = Array((0..<layerCapacity).reversed())
        var actions: [ReplayAction] = []

        for (commandIndex, command) in project.commands.enumerated() {
            switch command {
            case let .stroke(stroke):
                if relevantLayerIDs.contains(stroke.layerID) {
                    let slice = try acquireReplaySlice(
                        for: stroke.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.stroke(stroke, slice))
                } else {
                    actions.append(.simulateDiscardedStroke)
                }
            case let .clearLayer(clear):
                if relevantLayerIDs.contains(clear.layerID) {
                    let slice = try acquireReplaySlice(
                        for: clear.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.clear(slice))
                }
            case let .duplicateLayer(duplicate):
                if relevantLayerIDs.contains(duplicate.destinationLayerID) {
                    let source = try acquireReplaySlice(
                        for: duplicate.sourceLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    let destination = try acquireReplaySlice(
                        for: duplicate.destinationLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.duplicate(source, destination))
                }
            case let .mergeDown(merge):
                if relevantLayerIDs.contains(merge.destinationLayerID) {
                    let source = try acquireReplaySlice(
                        for: merge.sourceLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    let destination = try acquireReplaySlice(
                        for: merge.destinationLayerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.merge(source, destination))
                }
            case let .dryLayer(dry):
                if relevantLayerIDs.contains(dry.layerID) {
                    let slice = try acquireReplaySlice(
                        for: dry.layerID,
                        layerSlices: &layerSlices,
                        freeSlices: &freeSlices
                    )
                    actions.append(.dry(slice, max(0, dry.steps)))
                }
            }
            for layerID in releasesByCommand[commandIndex, default: []] {
                if let slice = layerSlices.removeValue(forKey: layerID) {
                    actions.append(.clear(slice))
                    freeSlices.append(slice)
                }
            }
        }
        for layer in project.layers {
            _ = try acquireReplaySlice(
                for: layer.id,
                layerSlices: &layerSlices,
                freeSlices: &freeSlices
            )
        }
        return ReplayPlan(actions: actions, finalLayerSlices: layerSlices)
    }

    private static func historicalLayerReleases(
        in project: PaintingProject,
        relevantLayerIDs: Set<UUID>,
        currentLayerIDs: Set<UUID>
    ) -> [Int: [UUID]] {
        var lastUse: [UUID: Int] = [:]
        for (index, command) in project.commands.enumerated() {
            let usedLayerIDs: [UUID]
            switch command {
            case let .stroke(stroke) where relevantLayerIDs.contains(stroke.layerID):
                usedLayerIDs = [stroke.layerID]
            case let .clearLayer(clear) where relevantLayerIDs.contains(clear.layerID):
                usedLayerIDs = [clear.layerID]
            case let .duplicateLayer(duplicate) where relevantLayerIDs.contains(duplicate.destinationLayerID):
                usedLayerIDs = [duplicate.sourceLayerID, duplicate.destinationLayerID]
            case let .mergeDown(merge) where relevantLayerIDs.contains(merge.destinationLayerID):
                usedLayerIDs = [merge.sourceLayerID, merge.destinationLayerID]
            case let .dryLayer(dry) where relevantLayerIDs.contains(dry.layerID):
                usedLayerIDs = [dry.layerID]
            default:
                usedLayerIDs = []
            }
            for layerID in usedLayerIDs where !currentLayerIDs.contains(layerID) {
                lastUse[layerID] = index
            }
        }
        return Dictionary(grouping: lastUse, by: \.value)
            .mapValues { $0.map(\.key) }
    }

    private static func acquireReplaySlice(
        for layerID: UUID,
        layerSlices: inout [UUID: Int],
        freeSlices: inout [Int]
    ) throws -> Int {
        if let existing = layerSlices[layerID] {
            return existing
        }
        guard let slice = freeSlices.popLast() else {
            throw RendererError.allocation("12 pigment slices for simultaneously active layers")
        }
        layerSlices[layerID] = slice
        return slice
    }

    private func updateLayerMetadata(
        project metadataProject: PaintingProject? = nil,
        opacityPreviews: [UUID: Double]? = nil
    ) {
        let metadataProject = metadataProject ?? project
        let opacityPreviews = opacityPreviews ?? layerOpacityPreviews
        let pointer = layerMetadataBuffer.contents().bindMemory(
            to: SIMD4<Float>.self,
            capacity: Self.layerCapacity
        )
        for index in 0..<Self.layerCapacity {
            pointer[index] = .zero
        }
        for (index, layer) in metadataProject.layers.enumerated() {
            guard let slice = layerSlices[layer.id] else { continue }
            pointer[index] = SIMD4(
                Float(slice),
                Float(min(max(opacityPreviews[layer.id] ?? layer.opacity, 0), 1)),
                layer.isVisible ? 1 : 0,
                0
            )
        }
    }

    private func encode(stroke: StrokeCommand, slice: Int, with encoder: MTLComputeCommandEncoder) {
        guard !stroke.points.isEmpty else { return }
        encoder.setComputePipelineState(stampPipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)

        let baseSeed = Self.seed(for: stroke.id)
        for (index, point) in stroke.points.enumerated() {
            let pressure = Float(min(max(point.pressure, 0), 1))
            let radius = max(Float(stroke.brush.size) * 0.5 * max(pressure, 0.12), 0.5)
            let horizontalRadius = radius * 1.25
            let verticalRadius = radius * 1.25
            let minX = max(Int(floor(point.x - Double(horizontalRadius) - 2)), 0)
            let minY = max(Int(floor(point.y - Double(verticalRadius) - 2)), 0)
            let maxX = min(Int(ceil(point.x + Double(horizontalRadius) + 2)), compositeTexture.width)
            let maxY = min(Int(ceil(point.y + Double(verticalRadius) + 2)), compositeTexture.height)
            guard maxX > minX, maxY > minY else { continue }

            var parameters = StampParameters(
                centerRadius: SIMD4(Float(point.x), Float(point.y), radius, radius),
                color: SIMD4(
                    Float(stroke.brush.color.red),
                    Float(stroke.brush.color.green),
                    Float(stroke.brush.color.blue),
                    Float(stroke.brush.color.alpha)
                ),
                brush: SIMD4(
                    pressure,
                    Float(stroke.brush.opacity),
                    Float(stroke.brush.flow),
                    Float(stroke.brush.water)
                ),
                effects: SIMD4(
                    Float(stroke.brush.granulation),
                    Float(stroke.brush.edgeBloom),
                    Float(point.tiltX),
                    Float(point.tiltY)
                ),
                modes: SIMD4(
                    Self.index(of: stroke.tool),
                    Self.index(of: stroke.brush.shape),
                    Self.index(of: stroke.brush.hair),
                    Self.index(of: stroke.brush.texture)
                ),
                extra: SIMD4(
                    Self.index(of: stroke.brush.style),
                    Self.index(of: project.paper),
                    UInt32(slice),
                    baseSeed ^ (UInt32(truncatingIfNeeded: index) &* 0x9e3779b9)
                ),
                stampRect: SIMD4(UInt32(minX), UInt32(minY), UInt32(maxX - minX), UInt32(maxY - minY))
            )
            encoder.setBytes(&parameters, length: MemoryLayout<StampParameters>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: maxX - minX, height: maxY - minY, depth: 1),
                threadsPerThreadgroup: threadgroupSize(for: stampPipeline)
            )
            encoder.memoryBarrier(scope: .textures)
        }
    }

    private func encodeSimulation(
        steps: Int,
        targetSlice: UInt32,
        with encoder: MTLComputeCommandEncoder
    ) {
        guard steps > 0 else { return }
        encoder.setComputePipelineState(simulationPipeline)
        var parameters = SimulationParameters(
            rates: SIMD4(0.24, 0.055, 0.985, 0),
            selection: SIMD4(targetSlice, 0, 0, 0)
        )
        encoder.setBytes(&parameters, length: MemoryLayout<SimulationParameters>.stride, index: 0)

        for _ in 0..<steps {
            let destination = 1 - frontTextureIndex
            encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
            encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
            encoder.setTexture(pigmentTextures[destination], index: 2)
            encoder.setTexture(wetnessTextures[destination], index: 3)
            encoder.dispatchThreads(
                MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: Self.layerCapacity),
                threadsPerThreadgroup: threadgroupSize(for: simulationPipeline)
            )
            encoder.memoryBarrier(scope: .textures)
            frontTextureIndex = destination
        }
    }

    private func encodeClear(
        targetSlice: UInt32,
        texturesAt index: Int,
        with encoder: MTLComputeCommandEncoder
    ) {
        encoder.setComputePipelineState(clearPipeline)
        encoder.setTexture(pigmentTextures[index], index: 0)
        encoder.setTexture(wetnessTextures[index], index: 1)
        var targetSlice = targetSlice
        encoder.setBytes(&targetSlice, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: Self.layerCapacity),
            threadsPerThreadgroup: threadgroupSize(for: clearPipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func encodeMerge(source: Int, destination: Int, with encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(mergePipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
        var slices = SIMD2(UInt32(source), UInt32(destination))
        encoder.setBytes(&slices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
            threadsPerThreadgroup: threadgroupSize(for: mergePipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func encodeCopy(source: Int, destination: Int, with encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(copyLayerPipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 1)
        var slices = SIMD2(UInt32(source), UInt32(destination))
        encoder.setBytes(&slices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
            threadsPerThreadgroup: threadgroupSize(for: copyLayerPipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func encodeComposite(
        with encoder: MTLComputeCommandEncoder,
        project compositeProject: PaintingProject? = nil,
        output: MTLTexture? = nil
    ) {
        let compositeProject = compositeProject ?? project
        let output = output ?? compositeTexture
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBuffer(layerMetadataBuffer, offset: 0, index: 0)
        var parameters = CompositeParameters(
            dimensions: SIMD4(
                UInt32(output.width),
                UInt32(output.height),
                Self.index(of: compositeProject.paper),
                UInt32(compositeProject.layers.count)
            )
        )
        encoder.setBytes(&parameters, length: MemoryLayout<CompositeParameters>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: threadgroupSize(for: compositePipeline)
        )
        encoder.memoryBarrier(scope: .textures)
    }

    private func prepareCompositeTransaction(
        project candidateProject: PaintingProject,
        opacityPreviews: [UUID: Double],
        label: String
    ) throws {
        updateLayerMetadata(project: candidateProject, opacityPreviews: opacityPreviews)
        do {
            let commandBuffer = try makeCommandBuffer(label: label)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.allocation("a layer metadata transaction encoder")
            }
            encoder.label = "Layer metadata transaction composite"
            encodeComposite(
                with: encoder,
                project: candidateProject,
                output: transactionCompositeTexture
            )
            encoder.endEncoding()
            try submit(commandBuffer, wait: true)
        } catch {
            updateLayerMetadata()
            throw error
        }
    }

    private var wetnessTileThreadgroupSize: MTLSize {
        Self.wetnessTileThreadgroupSize(for: wetnessTileMaximumPipeline)
    }

    private var wetnessFinalThreadgroupSize: MTLSize {
        Self.wetnessFinalThreadgroupSize(for: wetnessFinalMaximumPipeline)
    }

    private func prepareCanvasWetnessMeasurement() {
        wetnessMaximumBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
    }

    private func encodeCanvasWetnessMeasurement(with encoder: MTLComputeCommandEncoder) {
        let tileThreadgroupSize = wetnessTileThreadgroupSize
        let tileThreadCount = tileThreadgroupSize.width * tileThreadgroupSize.height
        encoder.setComputePipelineState(wetnessTileMaximumPipeline)
        encoder.setTexture(wetnessTextures[frontTextureIndex], index: 0)
        encoder.setBuffer(wetnessTileMaximumBuffer, offset: 0, index: 0)
        var activeSlices = project.layers.reduce(UInt32(0)) { mask, layer in
            guard let slice = layerSlices[layer.id] else { return mask }
            return mask | (UInt32(1) << UInt32(slice))
        }
        encoder.setBytes(&activeSlices, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setThreadgroupMemoryLength(
            tileThreadCount * MemoryLayout<UInt32>.stride,
            index: 0
        )
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: Self.layerCapacity),
            threadsPerThreadgroup: tileThreadgroupSize
        )
        encoder.memoryBarrier(scope: .buffers)

        let tileCount = Self.wetnessTileCount(
            width: compositeTexture.width,
            height: compositeTexture.height,
            threadsPerThreadgroup: tileThreadgroupSize
        )
        let finalThreadgroupSize = wetnessFinalThreadgroupSize
        encoder.setComputePipelineState(wetnessFinalMaximumPipeline)
        encoder.setBuffer(wetnessTileMaximumBuffer, offset: 0, index: 0)
        encoder.setBuffer(wetnessMaximumBuffer, offset: 0, index: 1)
        var tileCountParameter = UInt32(tileCount)
        encoder.setBytes(&tileCountParameter, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setThreadgroupMemoryLength(
            finalThreadgroupSize.width * MemoryLayout<UInt32>.stride,
            index: 0
        )
        encoder.dispatchThreads(finalThreadgroupSize, threadsPerThreadgroup: finalThreadgroupSize)
        encoder.memoryBarrier(scope: .buffers)
    }

    private func readCanvasWetnessMeasurement() {
        let maximum = wetnessMaximumBuffer.contents().load(as: UInt32.self)
        canvasWetness = min(max(Double(maximum) / 1_000_000, 0), 1)
    }

    private func makeCommandBuffer(label: String) throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.allocation("a Metal command buffer")
        }
        commandBuffer.label = label
        return commandBuffer
    }

    private func submit(_ commandBuffer: MTLCommandBuffer, wait: Bool) throws {
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
        if wait {
            commandBuffer.waitUntilCompleted()
            lastCommandBuffer = nil
            if let error = commandBufferError(commandBuffer) {
                throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
            }
        }
    }

    private func synchronizeGPU(readback: Bool) throws {
        guard let commandBuffer = lastCommandBuffer else { return }
        commandBuffer.waitUntilCompleted()
        lastCommandBuffer = nil
        if let error = commandBufferError(commandBuffer) {
            if readback {
                throw RendererError.readback(error.localizedDescription)
            }
            throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
        }
    }

    private func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let width = max(pipeline.threadExecutionWidth, 1)
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
        return MTLSize(width: width, height: height, depth: 1)
    }

    private static func wetnessTileThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let maximumThreads = largestPowerOfTwo(notExceeding: min(pipeline.maxTotalThreadsPerThreadgroup, 256))
        let width = min(max(pipeline.threadExecutionWidth, 1), maximumThreads)
        return MTLSize(width: width, height: max(maximumThreads / width, 1), depth: 1)
    }

    private static func wetnessFinalThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        MTLSize(
            width: largestPowerOfTwo(notExceeding: min(pipeline.maxTotalThreadsPerThreadgroup, 256)),
            height: 1,
            depth: 1
        )
    }

    private static func largestPowerOfTwo(notExceeding limit: Int) -> Int {
        var result = 1
        while result * 2 <= max(limit, 1) {
            result *= 2
        }
        return result
    }

    private static func wetnessTileCount(
        width: Int,
        height: Int,
        threadsPerThreadgroup: MTLSize
    ) -> Int {
        let groupsWide = (width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width
        let groupsHigh = (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height
        return groupsWide * groupsHigh * layerCapacity
    }

    private static func makeWetnessTileMaximumBuffer(device: MTLDevice, length: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: length, options: .storageModePrivate) else {
            throw RendererError.allocation("canvas wetness tile maxima")
        }
        buffer.label = "Canvas wetness tile maxima"
        return buffer
    }

    fileprivate static func makeComputePipeline(
        named name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw RendererError.shaderCompilation("Missing function \(name)")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw RendererError.shaderCompilation("\(name): \(error.localizedDescription)")
        }
    }

    fileprivate static func makeDisplayPipeline(
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "displayVertex"),
              let fragment = library.makeFunction(name: "displayFragment")
        else {
            throw RendererError.shaderCompilation("Missing display functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Watercolor display pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.shaderCompilation("display pipeline: \(error.localizedDescription)")
        }
    }

    private static func makeTextures(
        device: MTLDevice,
        width: Int,
        height: Int
    ) throws -> (
        pigment: [MTLTexture],
        wetness: [MTLTexture],
        composite: MTLTexture,
        transactionComposite: MTLTexture
    ) {
        guard width > 0, height > 0 else {
            throw RendererError.allocation("textures for a \(width) × \(height) canvas")
        }

        func makeArray(pixelFormat: MTLPixelFormat, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = pixelFormat
            descriptor.width = width
            descriptor.height = height
            descriptor.depth = 1
            descriptor.mipmapLevelCount = 1
            descriptor.arrayLength = layerCapacity
            descriptor.sampleCount = 1
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.allocation(label)
            }
            texture.label = label
            return texture
        }

        let pigment = try [
            makeArray(pixelFormat: .rgba16Float, label: "Pigment A"),
            makeArray(pixelFormat: .rgba16Float, label: "Pigment B")
        ]
        let wetness = try [
            makeArray(pixelFormat: .r16Float, label: "Wetness A"),
            makeArray(pixelFormat: .r16Float, label: "Wetness B")
        ]

        func makeComposite(label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RendererError.allocation(label)
            }
            texture.label = label
            return texture
        }
        return (
            pigment,
            wetness,
            try makeComposite(label: "Watercolor composite"),
            try makeComposite(label: "Watercolor transaction composite")
        )
    }

    private static func seed(for identifier: UUID) -> UInt32 {
        var uuid = identifier.uuid
        return withUnsafeBytes(of: &uuid) { bytes in
            bytes.reduce(UInt32(2_166_136_261)) { partial, byte in
                (partial ^ UInt32(byte)) &* 16_777_619
            }
        }
    }

    private static func index(of tool: PaintTool) -> UInt32 {
        switch tool {
        case .brush: 0
        case .water: 1
        case .eraser: 2
        case .smudge: 3
        case .smear: 4
        case .dry: 5
        }
    }

    private static func index(of shape: BrushShape) -> UInt32 {
        switch shape {
        case .round: 0
        case .flat: 1
        case .filbert: 2
        case .fan: 3
        case .rigger: 4
        }
    }

    private static func index(of hair: BrushHair) -> UInt32 {
        switch hair {
        case .sable: 0
        case .squirrel: 1
        case .synthetic: 2
        case .bristle: 3
        case .mop: 4
        }
    }

    private static func index(of texture: BrushTexture) -> UInt32 {
        switch texture {
        case .smooth: 0
        case .granulating: 1
        case .dry: 2
        case .mottled: 3
        case .salt: 4
        }
    }

    private static func index(of style: WatercolorStyle) -> UInt32 {
        switch style {
        case .transparentWash: 0
        case .wetOnWet: 1
        case .dryBrush: 2
        case .glazing: 3
        case .bloom: 4
        }
    }

    private static func index(of paper: PaperTexture) -> UInt32 {
        switch paper {
        case .hotPress: 0
        case .coldPress: 1
        case .rough: 2
        case .handmade: 3
        case .canvas: 4
        }
    }
}

@MainActor
private final class RendererPipelineResources {
    let stamp: MTLComputePipelineState
    let simulation: MTLComputePipelineState
    let clear: MTLComputePipelineState
    let copyLayer: MTLComputePipelineState
    let merge: MTLComputePipelineState
    let composite: MTLComputePipelineState
    let wetnessTileMaximum: MTLComputePipelineState
    let wetnessFinalMaximum: MTLComputePipelineState
    let display: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.watercolor, options: nil)
        } catch {
            throw RendererError.shaderCompilation(error.localizedDescription)
        }
        stamp = try WatercolorRenderer.makeComputePipeline(named: "stampKernel", library: library, device: device)
        simulation = try WatercolorRenderer.makeComputePipeline(
            named: "simulationKernel",
            library: library,
            device: device
        )
        clear = try WatercolorRenderer.makeComputePipeline(named: "clearKernel", library: library, device: device)
        copyLayer = try WatercolorRenderer.makeComputePipeline(
            named: "copyLayerKernel",
            library: library,
            device: device
        )
        merge = try WatercolorRenderer.makeComputePipeline(named: "mergeKernel", library: library, device: device)
        composite = try WatercolorRenderer.makeComputePipeline(
            named: "compositeKernel",
            library: library,
            device: device
        )
        wetnessTileMaximum = try WatercolorRenderer.makeComputePipeline(
            named: "wetnessTileMaximumKernel",
            library: library,
            device: device
        )
        wetnessFinalMaximum = try WatercolorRenderer.makeComputePipeline(
            named: "wetnessFinalMaximumKernel",
            library: library,
            device: device
        )
        display = try WatercolorRenderer.makeDisplayPipeline(library: library, device: device)
    }
}

private struct StampParameters {
    var centerRadius: SIMD4<Float>
    var color: SIMD4<Float>
    var brush: SIMD4<Float>
    var effects: SIMD4<Float>
    var modes: SIMD4<UInt32>
    var extra: SIMD4<UInt32>
    var stampRect: SIMD4<UInt32>
}

private struct SimulationParameters {
    var rates: SIMD4<Float>
    var selection: SIMD4<UInt32>
}

private struct CompositeParameters {
    var dimensions: SIMD4<UInt32>
}

private struct ReplayPlan {
    let actions: [ReplayAction]
    let finalLayerSlices: [UUID: Int]
}

private enum ReplayAction {
    case stroke(StrokeCommand, Int)
    case simulateDiscardedStroke
    case clear(Int)
    case duplicate(Int, Int)
    case merge(Int, Int)
    case dry(Int, Int)
}

#if DEBUG
struct RendererDebugResources: Equatable {
    let pigmentTextures: [ObjectIdentifier]
    let wetnessTextures: [ObjectIdentifier]
    let pipelines: [ObjectIdentifier]
    let compositeTextures: Set<ObjectIdentifier>
    let pigmentArrayLength: Int
    let wetnessArrayLength: Int
    let pigmentPixelFormat: MTLPixelFormat
    let wetnessPixelFormat: MTLPixelFormat
    let compositePixelFormat: MTLPixelFormat
}

struct RendererDebugWetnessReductionResources: Equatable {
    let tileMaximumBuffer: ObjectIdentifier
    let finalMaximumBuffer: ObjectIdentifier
    let firstStageThreadgroupCount: Int
    let finalStageThreadgroupCount: Int
}

extension WatercolorRenderer {
    var debugResources: RendererDebugResources {
        RendererDebugResources(
            pigmentTextures: pigmentTextures.map { ObjectIdentifier($0 as AnyObject) },
            wetnessTextures: wetnessTextures.map { ObjectIdentifier($0 as AnyObject) },
            pipelines: [
                stampPipeline,
                simulationPipeline,
                clearPipeline,
                copyLayerPipeline,
                mergePipeline,
                compositePipeline,
                wetnessTileMaximumPipeline,
                wetnessFinalMaximumPipeline,
                displayPipeline
            ].map { ObjectIdentifier($0 as AnyObject) },
            compositeTextures: [
                ObjectIdentifier(compositeTexture as AnyObject),
                ObjectIdentifier(transactionCompositeTexture as AnyObject)
            ],
            pigmentArrayLength: pigmentTextures[0].arrayLength,
            wetnessArrayLength: wetnessTextures[0].arrayLength,
            pigmentPixelFormat: pigmentTextures[0].pixelFormat,
            wetnessPixelFormat: wetnessTextures[0].pixelFormat,
            compositePixelFormat: compositeTexture.pixelFormat
        )
    }

    var debugReplayCount: Int {
        replayCount
    }

    var debugWetnessReductionResources: RendererDebugWetnessReductionResources {
        RendererDebugWetnessReductionResources(
            tileMaximumBuffer: ObjectIdentifier(wetnessTileMaximumBuffer as AnyObject),
            finalMaximumBuffer: ObjectIdentifier(wetnessMaximumBuffer as AnyObject),
            firstStageThreadgroupCount: Self.wetnessTileCount(
                width: compositeTexture.width,
                height: compositeTexture.height,
                threadsPerThreadgroup: wetnessTileThreadgroupSize
            ),
            finalStageThreadgroupCount: 1
        )
    }

    func debugPixel(x: Int, y: Int, layerID: UUID? = nil) throws -> PaintColor {
        let identifier = layerID ?? project.layers.last(where: \.isVisible)?.id ?? project.layers.last?.id
        guard let identifier, let slice = layerSlices[identifier] else {
            throw RendererError.readback("No layer is available for pigment inspection")
        }
        let values = try debugHalfValues(x: x, y: y, slice: slice, texture: pigmentTextures[frontTextureIndex], count: 4)
        return PaintColor(
            red: Double(values[0]),
            green: Double(values[1]),
            blue: Double(values[2]),
            alpha: Double(values[3])
        )
    }

    func debugWetness(x: Int, y: Int, layerID: UUID? = nil) throws -> Double {
        let identifier = layerID ?? project.layers.last(where: \.isVisible)?.id ?? project.layers.last?.id
        guard let identifier, let slice = layerSlices[identifier] else {
            throw RendererError.readback("No layer is available for wetness inspection")
        }
        return Double(try debugHalfValues(
            x: x,
            y: y,
            slice: slice,
            texture: wetnessTextures[frontTextureIndex],
            count: 1
        )[0])
    }

    func debugMaximumWetness() throws -> Double {
        let slices = project.layers.compactMap { layerSlices[$0.id] }
        guard !slices.isEmpty else { return 0 }
        let width = wetnessTextures[frontTextureIndex].width
        let height = wetnessTextures[frontTextureIndex].height
        let bytesPerRow = ((width * MemoryLayout<UInt16>.stride + 255) / 256) * 256
        let bytesPerImage = bytesPerRow * height
        guard let buffer = device.makeBuffer(
            length: bytesPerImage * slices.count,
            options: .storageModeShared
        ) else {
            throw RendererError.readback("Could not allocate the wetness verification buffer")
        }
        let commandBuffer = try makeCommandBuffer(label: "Verify canvas wetness")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the wetness verification encoder")
        }
        for (index, slice) in slices.enumerated() {
            encoder.copy(
                from: wetnessTextures[frontTextureIndex],
                sourceSlice: slice,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer,
                destinationOffset: index * bytesPerImage,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerImage
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }

        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var maximum: Float = 0
        for layerIndex in slices.indices {
            for y in 0..<height {
                for x in 0..<width {
                    let byteOffset = layerIndex * bytesPerImage + y * bytesPerRow + x * MemoryLayout<UInt16>.stride
                    let bits = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                    maximum = max(maximum, Float(Float16(bitPattern: bits)))
                }
            }
        }
        return Double(maximum)
    }

    private func debugHalfValues(
        x: Int,
        y: Int,
        slice: Int,
        texture: MTLTexture,
        count: Int
    ) throws -> [Float] {
        guard (0..<texture.width).contains(x), (0..<texture.height).contains(y) else {
            throw RendererError.readback("Pixel (\(x), \(y)) is outside the canvas")
        }
        guard let buffer = device.makeBuffer(length: 256, options: .storageModeShared) else {
            throw RendererError.readback("Could not allocate the debug readback buffer")
        }
        let commandBuffer = try makeCommandBuffer(label: "Inspect watercolor pixel")
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RendererError.readback("Could not create the debug readback encoder")
        }
        encoder.copy(
            from: texture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: 256,
            destinationBytesPerImage: 256
        )
        encoder.endEncoding()
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RendererError.readback(error.localizedDescription)
        }
        let pointer = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<count).map { Float(Float16(bitPattern: pointer[$0])) }
    }
}
#endif
