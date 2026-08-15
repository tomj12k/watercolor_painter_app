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

    /// The canvas-sized, top-left-oriented texture consumed by the MTKView display pass.
    public var renderedTexture: MTLTexture { compositeTexture }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let stampPipeline: MTLComputePipelineState
    private let simulationPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let mergePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let layerMetadataBuffer: MTLBuffer

    private var pigmentTextures: [MTLTexture]
    private var wetnessTextures: [MTLTexture]
    private var compositeTexture: MTLTexture
    private var frontTextureIndex = 0
    private var layerSlices: [UUID: Int] = [:]
    private var lastCommandBuffer: MTLCommandBuffer?

    public init(
        project: PaintingProject,
        device requestedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let requestedDevice else {
            throw RendererError.metalUnavailable
        }
        guard let commandQueue = requestedDevice.makeCommandQueue() else {
            throw RendererError.allocation("a Metal command queue")
        }

        let library: MTLLibrary
        do {
            library = try requestedDevice.makeLibrary(source: ShaderSource.watercolor, options: nil)
        } catch {
            throw RendererError.shaderCompilation(error.localizedDescription)
        }

        self.device = requestedDevice
        self.commandQueue = commandQueue
        stampPipeline = try Self.makeComputePipeline(named: "stampKernel", library: library, device: requestedDevice)
        simulationPipeline = try Self.makeComputePipeline(named: "simulationKernel", library: library, device: requestedDevice)
        clearPipeline = try Self.makeComputePipeline(named: "clearKernel", library: library, device: requestedDevice)
        mergePipeline = try Self.makeComputePipeline(named: "mergeKernel", library: library, device: requestedDevice)
        compositePipeline = try Self.makeComputePipeline(named: "compositeKernel", library: library, device: requestedDevice)
        displayPipeline = try Self.makeDisplayPipeline(library: library, device: requestedDevice)

        guard let layerMetadataBuffer = requestedDevice.makeBuffer(
            length: Self.layerCapacity * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ) else {
            throw RendererError.allocation("layer metadata")
        }
        self.layerMetadataBuffer = layerMetadataBuffer

        let textures = try Self.makeTextures(
            device: requestedDevice,
            width: project.canvas.width,
            height: project.canvas.height
        )
        pigmentTextures = textures.pigment
        wetnessTextures = textures.wetness
        compositeTexture = textures.composite
        self.project = project
        viewportSize = CGSize(width: project.canvas.width, height: project.canvas.height)

        super.init()
        try replay(project: project)
    }

    public func resizeViewport(_ size: CGSize) {
        viewportSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    public func render(stroke: StrokeCommand) throws {
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
        encoder.endEncoding()
        try submit(commandBuffer, wait: false)
    }

    public func replay(project newProject: PaintingProject) throws {
        let replayPlan = try Self.makeReplayPlan(for: newProject)
        try synchronizeGPU(readback: false)
        let replacementTextures: (pigment: [MTLTexture], wetness: [MTLTexture], composite: MTLTexture)?
        if newProject.canvas.width != compositeTexture.width || newProject.canvas.height != compositeTexture.height {
            replacementTextures = try Self.makeTextures(
                device: device,
                width: newProject.canvas.width,
                height: newProject.canvas.height
            )
        } else {
            replacementTextures = nil
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
            viewportSize = CGSize(width: newProject.canvas.width, height: newProject.canvas.height)
        }
        project = newProject
        layerSlices = replayPlan.finalLayerSlices
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
            case let .clear(slice):
                encodeClear(targetSlice: UInt32(slice), texturesAt: frontTextureIndex, with: encoder)
            case let .merge(source, destination):
                encodeMerge(source: source, destination: destination, with: encoder)
            case let .dry(slice, steps):
                encodeSimulation(steps: steps, targetSlice: UInt32(slice), with: encoder)
            }
        }

        encodeComposite(with: encoder)
        encoder.endEncoding()
        try submit(commandBuffer, wait: true)
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
        encoder.endEncoding()
        try submit(commandBuffer, wait: false)
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
            if case let .mergeDown(merge) = command,
               relevant.contains(merge.destinationLayerID) {
                relevant.insert(merge.sourceLayerID)
            }
        }
        return relevant
    }

    private static func makeReplayPlan(for project: PaintingProject) throws -> ReplayPlan {
        let relevantLayerIDs = try relevantLayerIDs(in: project)
        var layerSlices: [UUID: Int] = [:]
        var freeSlices = Array((0..<layerCapacity).reversed())
        var actions: [ReplayAction] = []

        for command in project.commands {
            switch command {
            case let .stroke(stroke):
                guard relevantLayerIDs.contains(stroke.layerID) else { continue }
                let slice = try acquireReplaySlice(
                    for: stroke.layerID,
                    layerSlices: &layerSlices,
                    freeSlices: &freeSlices
                )
                actions.append(.stroke(stroke, slice))
            case let .clearLayer(clear):
                guard relevantLayerIDs.contains(clear.layerID) else { continue }
                let slice = try acquireReplaySlice(
                    for: clear.layerID,
                    layerSlices: &layerSlices,
                    freeSlices: &freeSlices
                )
                actions.append(.clear(slice))
            case let .mergeDown(merge):
                guard relevantLayerIDs.contains(merge.destinationLayerID) else { continue }
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
                if source != destination {
                    layerSlices.removeValue(forKey: merge.sourceLayerID)
                    freeSlices.append(source)
                }
            case let .dryLayer(dry):
                guard relevantLayerIDs.contains(dry.layerID) else { continue }
                let slice = try acquireReplaySlice(
                    for: dry.layerID,
                    layerSlices: &layerSlices,
                    freeSlices: &freeSlices
                )
                actions.append(.dry(slice, max(0, dry.steps)))
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

    private func updateLayerMetadata() {
        let pointer = layerMetadataBuffer.contents().bindMemory(
            to: SIMD4<Float>.self,
            capacity: Self.layerCapacity
        )
        for index in 0..<Self.layerCapacity {
            pointer[index] = .zero
        }
        for (index, layer) in project.layers.enumerated() {
            guard let slice = layerSlices[layer.id] else { continue }
            pointer[index] = SIMD4(
                Float(slice),
                Float(min(max(layer.opacity, 0), 1)),
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

    private func encodeComposite(with encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(pigmentTextures[frontTextureIndex], index: 0)
        encoder.setTexture(compositeTexture, index: 1)
        encoder.setBuffer(layerMetadataBuffer, offset: 0, index: 0)
        var parameters = CompositeParameters(
            dimensions: SIMD4(
                UInt32(compositeTexture.width),
                UInt32(compositeTexture.height),
                Self.index(of: project.paper),
                UInt32(project.layers.count)
            )
        )
        encoder.setBytes(&parameters, length: MemoryLayout<CompositeParameters>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
            threadsPerThreadgroup: threadgroupSize(for: compositePipeline)
        )
        encoder.memoryBarrier(scope: .textures)
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
            if let error = commandBuffer.error {
                throw RendererError.allocation("GPU execution: \(error.localizedDescription)")
            }
        }
    }

    private func synchronizeGPU(readback: Bool) throws {
        guard let lastCommandBuffer else { return }
        lastCommandBuffer.waitUntilCompleted()
        if let error = lastCommandBuffer.error {
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

    private static func makeComputePipeline(
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

    private static func makeDisplayPipeline(
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
    ) throws -> (pigment: [MTLTexture], wetness: [MTLTexture], composite: MTLTexture) {
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

        let compositeDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        compositeDescriptor.storageMode = .shared
        compositeDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let composite = device.makeTexture(descriptor: compositeDescriptor) else {
            throw RendererError.allocation("the composite texture")
        }
        composite.label = "Watercolor composite"
        return (pigment, wetness, composite)
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
    case clear(Int)
    case merge(Int, Int)
    case dry(Int, Int)
}

#if DEBUG
struct RendererDebugResources: Equatable {
    let pigmentTextures: [ObjectIdentifier]
    let wetnessTextures: [ObjectIdentifier]
    let pipelines: [ObjectIdentifier]
    let pigmentArrayLength: Int
    let wetnessArrayLength: Int
    let pigmentPixelFormat: MTLPixelFormat
    let wetnessPixelFormat: MTLPixelFormat
    let compositePixelFormat: MTLPixelFormat
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
                mergePipeline,
                compositePipeline,
                displayPipeline
            ].map { ObjectIdentifier($0 as AnyObject) },
            pigmentArrayLength: pigmentTextures[0].arrayLength,
            wetnessArrayLength: wetnessTextures[0].arrayLength,
            pigmentPixelFormat: pigmentTextures[0].pixelFormat,
            wetnessPixelFormat: wetnessTextures[0].pixelFormat,
            compositePixelFormat: compositeTexture.pixelFormat
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
