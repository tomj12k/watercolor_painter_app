import CoreGraphics
import Metal
import Testing
import WatercolorCore
@testable import WatercolorEngine

@Suite @MainActor struct WatercolorRendererTests {
    @Test func redAndBlueWetStrokesMix() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testLine(
            layerID: project.layers[0].id,
            color: PaintColor(red: 1, green: 0, blue: 0),
            y: 32,
            water: 0.9
        ))
        try renderer.render(stroke: .testLine(
            layerID: project.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            y: 32,
            water: 0.9
        ))

        let pixel = try renderer.debugPixel(x: 32, y: 32)
        #expect(pixel.red > 0.1)
        #expect(pixel.blue > 0.1)
    }

    @Test func transparentPigmentDoesNotTintLaterMixing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        try renderer.render(stroke: .testDot(
            layerID: layerID,
            color: PaintColor(red: 1, green: 0, blue: 0, alpha: 0)
        ))
        try renderer.render(stroke: .testDot(
            layerID: layerID,
            color: PaintColor(red: 0, green: 0, blue: 1, alpha: 1)
        ))

        let mixed = try renderer.debugPixel(x: 32, y: 32)
        #expect(mixed.red < 0.01)
        #expect(mixed.blue > 0.1)
    }

    @Test func eraserLowersConcentration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: .brush, pressure: 1))
        let before = try renderer.debugPixel(x: 32, y: 32).alpha
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: .eraser, pressure: 1))

        #expect(try renderer.debugPixel(x: 32, y: 32).alpha < before)
    }

    @Test func rendererAllocatesFixedReusableTextureArrays() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = renderer.debugResources

        try renderer.render(stroke: .testDot(layerID: project.layers[0].id))
        let after = renderer.debugResources

        #expect(before == after)
        #expect(before.pigmentArrayLength == 12)
        #expect(before.wetnessArrayLength == 12)
        #expect(before.pigmentPixelFormat == .rgba16Float)
        #expect(before.wetnessPixelFormat == .r16Float)
        #expect(before.compositePixelFormat == .bgra8Unorm)
    }

    @Test func structuralCandidatesShareCompiledPipelinesButOwnTheirTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        var structuralProject = project
        structuralProject.layers.append(PaintLayer(name: "Second"))

        let candidate = try renderer.makeCandidate(project: structuralProject)

        #expect(candidate.debugResources.pipelines == renderer.debugResources.pipelines)
        #expect(
            Set(candidate.debugResources.pigmentTextures)
                .isDisjoint(with: Set(renderer.debugResources.pigmentTextures))
        )
        #expect(
            candidate.debugResources.compositeTextures
                .isDisjoint(with: renderer.debugResources.compositeTextures)
        )
    }

    @Test func replayIsDeterministic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .rough)
        project.commands = [
            .stroke(.testLine(
                id: UUID(uuidString: "82C2BD68-8748-4015-B501-D241D639A881")!,
                layerID: project.layers[0].id,
                color: PaintColor(red: 0.2, green: 0.6, blue: 0.9),
                y: 31,
                water: 0.85
            )),
            .dryLayer(DryLayerCommand(layerID: project.layers[0].id, steps: 3))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.replay(project: project)
        let first = try renderer.debugPixel(x: 29, y: 31)
        try renderer.replay(project: project)
        let second = try renderer.debugPixel(x: 29, y: 31)

        #expect(first == second)
    }

    @Test func discardedStrokeStillAdvancesSurvivingWetLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let layerID = base.layers[0].id
        var survivingStroke = StrokeCommand.testDot(
            id: UUID(uuidString: "6DF572F1-2C3C-4121-8A77-6A59A154E61F")!,
            layerID: layerID,
            color: PaintColor(red: 0.1, green: 0.4, blue: 0.8)
        )
        survivingStroke.brush.water = 0.95

        var explicitAdvance = base
        explicitAdvance.commands = [
            .stroke(survivingStroke),
            .dryLayer(DryLayerCommand(layerID: layerID, steps: 2))
        ]
        let renderer = try WatercolorRenderer(project: explicitAdvance, device: device)
        let expectedPigment = try renderer.debugPixel(x: 32, y: 32, layerID: layerID)
        let expectedWetness = try renderer.debugWetness(x: 32, y: 32, layerID: layerID)

        var discardedStroke = base
        discardedStroke.commands = [
            .stroke(survivingStroke),
            .stroke(.testDot(
                id: UUID(uuidString: "E1B79612-52A7-4BEF-8E32-224B10B78E4D")!,
                layerID: UUID(uuidString: "8393575B-86A6-459F-9097-9C9D28663C7D")!
            ))
        ]
        try renderer.replay(project: discardedStroke)

        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: layerID) == expectedPigment)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: layerID) == expectedWetness)
    }

    @Test func unknownLayerProducesUsefulError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let missingID = UUID(uuidString: "06E6D10C-F2B3-4BC4-B7BA-31067132045D")!

        #expect(throws: RendererError.unknownLayer(missingID)) {
            try renderer.render(stroke: .testDot(layerID: missingID))
        }
    }

    @Test func failedCompletedStrokeDoesNotPoisonRecoveryOrTheNextStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "deterministic GPU execution failure"]
        )
        var failedBuffer: MTLCommandBuffer?
        var observedStatus: MTLCommandBufferStatus?
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if failedBuffer == nil, commandBuffer.label == "Watercolor stroke" {
                    failedBuffer = commandBuffer
                }
                guard let failedBuffer, commandBuffer === failedBuffer else {
                    return commandBuffer.error
                }
                observedStatus = commandBuffer.status
                return injectedError
            }
        )
        let checksumBefore = try renderer.compositeChecksum()

        #expect(throws: RendererError.self) {
            try renderer.renderAndWait(stroke: .testDot(
                layerID: project.layers[0].id,
                x: 20,
                y: 32
            ))
        }
        #expect(observedStatus == .completed)

        try renderer.replay(project: project)
        #expect(try renderer.compositeChecksum() == checksumBefore)

        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "FECCAE3B-FB8B-43E4-A44D-695946AFDDC1")!,
            layerID: project.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            x: 44,
            y: 32
        ))
        #expect(try renderer.debugPixel(x: 20, y: 32).alpha == 0)
        #expect(try renderer.debugPixel(x: 44, y: 32).blue > 0.1)
    }

    @Test func everyToolHasItsOwnPigmentOrWetnessEffect() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let layerID = project.layers[0].id
        let renderer = try WatercolorRenderer(project: project, device: device)

        try renderer.render(stroke: .testDot(layerID: layerID, tool: .water))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha == 0)
        #expect(try renderer.debugWetness(x: 32, y: 32) > 0.1)

        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID))
        let painted = try renderer.debugPixel(x: 32, y: 32).alpha
        let wet = try renderer.debugWetness(x: 32, y: 32)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .eraser))
        #expect(try renderer.debugPixel(x: 32, y: 32).alpha < painted)

        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .water))
        let waterBeforeDryTool = try renderer.debugWetness(x: 32, y: 32)
        try renderer.render(stroke: .testDot(layerID: layerID, tool: .dry))
        #expect(try renderer.debugWetness(x: 32, y: 32) < waterBeforeDryTool)

        let smudgeSignature = try transformedSignature(tool: .smudge, project: project, renderer: renderer)
        let smearSignature = try transformedSignature(tool: .smear, project: project, renderer: renderer)
        #expect(smudgeSignature != smearSignature)
        #expect(wet > 0)
    }

    @Test func everyBrushAndPaperEnumChangesTheDeposit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: base, device: device)

        let shapeSignatures = try BrushShape.allCases.map { shape in
            try depositSignature(project: base, renderer: renderer) { $0.shape = shape }
        }
        let hairSignatures = try BrushHair.allCases.map { hair in
            try depositSignature(project: base, renderer: renderer) { $0.hair = hair }
        }
        let textureSignatures = try BrushTexture.allCases.map { texture in
            try depositSignature(project: base, renderer: renderer) { $0.texture = texture }
        }
        let styleSignatures = try WatercolorStyle.allCases.map { style in
            try depositSignature(project: base, renderer: renderer) { $0.style = style }
        }
        let paperSignatures = try PaperTexture.allCases.map { paper in
            var project = base
            project.paper = paper
            return try depositSignature(project: project, renderer: renderer) { _ in }
        }
        let noBloom = try depositSignature(project: base, renderer: renderer) { $0.edgeBloom = 0 }
        let fullBloom = try depositSignature(project: base, renderer: renderer) { $0.edgeBloom = 1 }

        #expect(Set(shapeSignatures).count == BrushShape.allCases.count)
        #expect(Set(hairSignatures).count == BrushHair.allCases.count)
        #expect(Set(textureSignatures).count == BrushTexture.allCases.count)
        #expect(Set(styleSignatures).count == WatercolorStyle.allCases.count)
        #expect(Set(paperSignatures).count == PaperTexture.allCases.count)
        #expect(noBloom != fullBloom)
    }

    @Test func layerVisibilityOpacityAndOrderAffectComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(
            id: UUID(uuidString: "728C677B-6290-4433-B161-06622DD8D541")!,
            name: "Bottom"
        )
        let top = PaintLayer(
            id: UUID(uuidString: "0941726A-63AA-4089-A251-C9B0DD2A8652")!,
            name: "Top"
        )
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let blueOnTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers[1].isVisible = false
        try renderer.replay(project: project)
        let hiddenTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers[1].isVisible = true
        project.layers[1].opacity = 0.2
        try renderer.replay(project: project)
        let translucentTop = try renderer.compositePixel(x: 32, y: 32)

        project.layers = [top, bottom]
        project.layers[0].opacity = 1
        try renderer.replay(project: project)
        let redOnTop = try renderer.compositePixel(x: 32, y: 32)

        #expect(blueOnTop.blue > hiddenTop.blue)
        #expect(hiddenTop.red > blueOnTop.red)
        #expect(translucentTop.blue > hiddenTop.blue)
        #expect(translucentTop.blue < blueOnTop.blue)
        #expect(redOnTop.red > redOnTop.blue)
    }

    @Test func layerOpacityPreviewRecompositesWithoutChangingTheProject() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let before = try renderer.compositePixel(x: 32, y: 32)

        try renderer.previewLayerOpacity(id: top.id, opacity: 0.1)
        let preview = try renderer.compositePixel(x: 32, y: 32)

        #expect(renderer.project == project)
        #expect(preview.blue < before.blue)
        #expect(preview.red > before.red)

        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositePixel(x: 32, y: 32) == before)
        #expect(renderer.project == project)
    }

    @Test func metadataTransactionReusesResourcesWithoutReplayAndUpdatesTheComposite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let checksumBefore = try renderer.compositeChecksum()
        var updated = project
        updated.layers.reverse()
        updated.layers[0].opacity = 0.25

        try renderer.applyMetadata(project: updated)

        #expect(renderer.project == updated)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(try renderer.compositeChecksum() != checksumBefore)
    }

    @Test func metadataTransactionRejectsPaperChangesWithoutMutatingTheRenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .coldPress)
        project.commands = [.stroke(.testDot(layerID: project.layers[0].id))]
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugResources
        let replayCountBefore = renderer.debugReplayCount
        let checksumBefore = try renderer.compositeChecksum()
        let pigmentBefore = try renderer.debugPixel(x: 32, y: 32, layerID: project.layers[0].id)
        let wetnessBefore = try renderer.debugWetness(x: 32, y: 32, layerID: project.layers[0].id)
        var updated = project
        updated.paper = .rough

        #expect(throws: RendererError.invalidMetadataChange) {
            try renderer.applyMetadata(project: updated)
        }

        #expect(renderer.project == project)
        #expect(renderer.debugResources == resourcesBefore)
        #expect(renderer.debugReplayCount == replayCountBefore)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: project.layers[0].id) == pigmentBefore)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: project.layers[0].id) == wetnessBefore)
    }

    @Test func failedOpacityPreviewLeavesCommittedMetadataAndAllowsTheNextPreview() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .hotPress,
            layers: [bottom, top]
        )
        project.commands = [
            .stroke(.testDot(layerID: bottom.id, color: PaintColor(red: 1, green: 0, blue: 0))),
            .stroke(.testDot(layerID: top.id, color: PaintColor(red: 0, green: 0, blue: 1)))
        ]
        let injectedError = NSError(
            domain: "WatercolorRendererTests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "preview recomposite failed"]
        )
        var shouldFailPreview = false
        let renderer = try WatercolorRenderer(
            project: project,
            device: device,
            debugCommandBufferError: { commandBuffer in
                if shouldFailPreview, commandBuffer.label == "Preview layer metadata" {
                    return injectedError
                }
                return commandBuffer.error
            }
        )
        let committedChecksum = try renderer.compositeChecksum()
        shouldFailPreview = true

        #expect(throws: RendererError.self) {
            try renderer.previewLayerOpacity(id: top.id, opacity: 0.1)
        }

        #expect(try renderer.compositeChecksum() == committedChecksum)
        shouldFailPreview = false
        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositeChecksum() == committedChecksum)

        try renderer.previewLayerOpacity(id: top.id, opacity: 0.2)
        #expect(try renderer.compositeChecksum() != committedChecksum)
        try renderer.clearLayerOpacityPreview(id: top.id)
        #expect(try renderer.compositeChecksum() == committedChecksum)
    }

    @Test func imageReadbackKeepsCanvasTopAtFirstRow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var project = PaintingProject.testCanvas(64, paper: .hotPress)
        project.commands = [
            .stroke(.testDot(
                layerID: project.layers[0].id,
                color: PaintColor(red: 1, green: 0, blue: 0),
                x: 32,
                y: 8
            )),
            .stroke(.testDot(
                layerID: project.layers[0].id,
                color: PaintColor(red: 0, green: 0, blue: 1),
                x: 32,
                y: 56
            ))
        ]
        let renderer = try WatercolorRenderer(project: project, device: device)

        let top = try renderer.compositePixel(x: 32, y: 8)
        let bottom = try renderer.compositePixel(x: 32, y: 56)

        #expect(top.red > top.blue)
        #expect(bottom.blue > bottom.red)
    }

    @Test func replayHonorsMergeAndClearCommandsInOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let destination = PaintLayer(
            id: UUID(uuidString: "86C089A3-CFFA-44F9-B7F0-57FE68572C25")!,
            name: "Destination"
        )
        let historicalSourceID = UUID(uuidString: "18B8DA86-0C8A-4E98-B7E5-232434CB3839")!
        var merged = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination]
        )
        merged.commands = [
            .stroke(.testDot(
                layerID: destination.id,
                color: PaintColor(red: 0, green: 0, blue: 1)
            )),
            .stroke(.testDot(
                layerID: historicalSourceID,
                color: PaintColor(red: 1, green: 0, blue: 0)
            )),
            .mergeDown(MergeDownCommand(
                sourceLayerID: historicalSourceID,
                destinationLayerID: destination.id
            ))
        ]
        let renderer = try WatercolorRenderer(project: merged, device: device)
        let mixed = try renderer.debugPixel(x: 32, y: 32, layerID: destination.id)
        #expect(mixed.red > 0.1)
        #expect(mixed.blue > 0.1)

        var cleared = merged
        cleared.commands.append(.clearLayer(LayerCommand(layerID: destination.id)))
        try renderer.replay(project: cleared)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: destination.id).alpha == 0)
    }

    @Test func replayDuplicatesPigmentAndWetnessThenLetsLayersDiverge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(
            id: UUID(uuidString: "C3A83C61-78CF-424E-BE87-B1F06BBEC732")!,
            name: "Source"
        )
        let destination = PaintLayer(
            id: UUID(uuidString: "B20C2C0C-A93B-4777-A98E-F82D82979C5E")!,
            name: "Destination"
        )
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [source, destination]
        )
        project.commands = [
            .stroke(.testDot(
                id: UUID(uuidString: "41A630AF-42F0-4905-A7D5-14E48A39F493")!,
                layerID: source.id,
                color: PaintColor(red: 1, green: 0, blue: 0),
                x: 20,
                y: 32
            )),
            .duplicateLayer(DuplicateLayerCommand(
                sourceLayerID: source.id,
                destinationLayerID: destination.id
            )),
            .stroke(.testDot(
                id: UUID(uuidString: "D2D9CB17-4C8D-4D8A-9C29-7A6C8CF6A8EF")!,
                layerID: source.id,
                color: PaintColor(red: 0, green: 0, blue: 1),
                x: 44,
                y: 32
            ))
        ]

        let renderer = try WatercolorRenderer(project: project, device: device)

        let sourceCopyPoint = try renderer.debugPixel(x: 20, y: 32, layerID: source.id)
        let destinationCopyPoint = try renderer.debugPixel(x: 20, y: 32, layerID: destination.id)
        #expect(sourceCopyPoint.red > 0.1)
        #expect(destinationCopyPoint.red > 0.1)
        #expect(try renderer.debugWetness(x: 20, y: 32, layerID: destination.id) > 0.01)
        #expect(try renderer.debugPixel(x: 44, y: 32, layerID: source.id).blue > 0.1)
        #expect(try renderer.debugPixel(x: 44, y: 32, layerID: destination.id).blue == 0)
    }

    @Test func encodedDuplicateProjectReplaysIdenticallyAfterDecode() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(name: "Source")
        let destination = PaintLayer(name: "Destination")
        var project = PaintingProject(
            canvas: CanvasSize(width: 256, height: 256),
            paper: .rough,
            layers: [source, destination]
        )
        project.commands = [
            .stroke(.testDot(layerID: source.id, x: 128, y: 128)),
            .duplicateLayer(DuplicateLayerCommand(
                sourceLayerID: source.id,
                destinationLayerID: destination.id
            ))
        ]
        let originalRenderer = try WatercolorRenderer(project: project, device: device)

        let data = try PaintingDocumentCodec.encode(project)
        let decoded = try PaintingDocumentCodec.decode(data)
        let decodedRenderer = try WatercolorRenderer(project: decoded, device: device)

        #expect(decoded == project)
        #expect(try decodedRenderer.compositeChecksum() == originalRenderer.compositeChecksum())
        #expect(
            try decodedRenderer.debugWetness(x: 128, y: 128, layerID: destination.id)
                == originalRenderer.debugWetness(x: 128, y: 128, layerID: destination.id)
        )
    }

    @Test func replayReusesSlicesForSequentialHistoricalLayers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let base = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: base, device: device)
        let destination = PaintLayer(name: "Surviving layer")
        let historicalLayerIDs = (0..<13).map { _ in UUID() }
        var project = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination]
        )
        project.commands = historicalLayerIDs.flatMap { sourceID in
            [
                .stroke(.testDot(
                    layerID: sourceID,
                    color: PaintColor(red: 1, green: 0, blue: 0)
                )),
                .mergeDown(MergeDownCommand(
                    sourceLayerID: sourceID,
                    destinationLayerID: destination.id
                ))
            ]
        }

        try renderer.replay(project: project)

        let merged = try renderer.debugPixel(x: 32, y: 32, layerID: destination.id)
        #expect(merged.red > 0.1)
        #expect(merged.alpha > 0.1)
        #expect(renderer.debugResources.pigmentArrayLength == 12)
    }

    @Test func replayReleasesDuplicateSourcesAfterTheirLastRelevantUse() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstLayer = PaintLayer(name: "Generation 0")
        let originalStroke = StrokeCommand.testDot(layerID: firstLayer.id, x: 32, y: 32)
        let original = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [firstLayer],
            commands: [.stroke(originalStroke)]
        )
        let expectedRenderer = try WatercolorRenderer(project: original, device: device)
        let expectedPixel = try expectedRenderer.debugPixel(x: 32, y: 32)
        let expectedWetness = try expectedRenderer.debugWetness(x: 32, y: 32)
        var editor = ProjectEditor(project: original)

        for generation in 1...16 {
            let sourceID = try #require(editor.project.layers.first?.id)
            try editor.duplicateLayer(id: sourceID, named: "Generation \(generation)")
            try editor.removeLayer(id: sourceID)
        }

        let renderer = try WatercolorRenderer(project: editor.project, device: device)
        let currentLayerID = try #require(editor.project.layers.first?.id)

        #expect(editor.project.layers.count == 1)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: currentLayerID) == expectedPixel)
        #expect(try renderer.debugWetness(x: 32, y: 32, layerID: currentLayerID) == expectedWetness)
    }

    @Test func aReusedHistoricalSliceStartsBlankAfterDuplicateSourceRelease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let source = PaintLayer(name: "Source")
        let destination = PaintLayer(name: "Destination")
        let laterHistorical = PaintLayer(name: "Later historical")
        let sourceStroke = StrokeCommand.testDot(
            layerID: source.id,
            color: PaintColor(red: 1, green: 0, blue: 0),
            x: 20,
            y: 32
        )
        let laterStroke = StrokeCommand.testDot(
            layerID: laterHistorical.id,
            color: PaintColor(red: 0, green: 0, blue: 1),
            x: 44,
            y: 32
        )
        let duplicate = PaintingCommand.duplicateLayer(DuplicateLayerCommand(
            sourceLayerID: source.id,
            destinationLayerID: destination.id
        ))
        let merge = PaintingCommand.mergeDown(MergeDownCommand(
            sourceLayerID: laterHistorical.id,
            destinationLayerID: destination.id
        ))
        let base = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .coldPress,
            layers: [destination],
            commands: [.stroke(sourceStroke), duplicate, .stroke(laterStroke), merge]
        )
        var explicitlyCleared = base
        explicitlyCleared.commands.insert(
            .clearLayer(LayerCommand(layerID: laterHistorical.id)),
            at: 2
        )

        let renderer = try WatercolorRenderer(project: base, device: device)
        let expectedRenderer = try WatercolorRenderer(project: explicitlyCleared, device: device)

        #expect(try renderer.compositeChecksum() == expectedRenderer.compositeChecksum())
        #expect(
            try renderer.debugWetness(x: 20, y: 32, layerID: destination.id)
                == expectedRenderer.debugWetness(x: 20, y: 32, layerID: destination.id)
        )
    }

    @Test func rejectedReplayLeavesPreviousProjectAndImageUsable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let original = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: original, device: device)
        try renderer.render(stroke: .testDot(
            layerID: original.layers[0].id,
            color: PaintColor(red: 1, green: 0, blue: 0)
        ))
        let projectBefore = renderer.project
        let checksumBefore = try renderer.compositeChecksum()
        let pigmentBefore = try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id)
        let destination = PaintLayer(name: "Destination")
        let simultaneousSourceIDs = (0..<13).map { _ in UUID() }
        var rejected = PaintingProject(
            canvas: CanvasSize(width: 64, height: 64),
            paper: .rough,
            layers: [destination]
        )
        rejected.commands = simultaneousSourceIDs.map { sourceID in
            .stroke(.testDot(layerID: sourceID))
        } + simultaneousSourceIDs.map { sourceID in
            .mergeDown(MergeDownCommand(
                sourceLayerID: sourceID,
                destinationLayerID: destination.id
            ))
        }

        #expect(throws: RendererError.self) {
            try renderer.replay(project: rejected)
        }

        #expect(renderer.project == projectBefore)
        #expect(try renderer.compositeChecksum() == checksumBefore)
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id) == pigmentBefore)
        try renderer.render(stroke: .testDot(
            layerID: original.layers[0].id,
            color: PaintColor(red: 0, green: 0, blue: 1)
        ))
        #expect(try renderer.debugPixel(x: 32, y: 32, layerID: original.layers[0].id).blue > 0.1)
    }

    @Test func pressureControlsDepositAndDryingEvaporatesWetness() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        try renderer.render(stroke: .testDot(layerID: layerID, pressure: 0.25))
        let lightDeposit = try renderer.debugPixel(x: 32, y: 32).alpha
        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: layerID, pressure: 1))
        let heavyDeposit = try renderer.debugPixel(x: 32, y: 32).alpha
        let wetBefore = try renderer.debugWetness(x: 32, y: 32)
        try renderer.dry(layerID: layerID, steps: 8)

        #expect(heavyDeposit > lightDeposit)
        #expect(try renderer.debugWetness(x: 32, y: 32) < wetBefore)
    }

    @Test func canvasWetnessTracksRealRenderingReplayAndDrying() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let project = PaintingProject.testCanvas(64)
        let renderer = try WatercolorRenderer(project: project, device: device)
        let layerID = project.layers[0].id

        #expect(renderer.canvasWetness == 0)

        try renderer.renderAndWait(stroke: .testDot(layerID: layerID, tool: .water))
        let wetAfterStroke = renderer.canvasWetness
        #expect(wetAfterStroke > 0.1)

        try renderer.dry(layerID: layerID, steps: 24)
        #expect(renderer.canvasWetness < wetAfterStroke)

        try renderer.replay(project: project)
        #expect(renderer.canvasWetness == 0)
    }

    @Test func stagedWetnessReductionIsAccurateBoundedAndReusesItsBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bottom = PaintLayer(name: "Bottom")
        let top = PaintLayer(name: "Top")
        let project = PaintingProject(
            canvas: CanvasSize(width: 257, height: 259),
            paper: .coldPress,
            layers: [bottom, top]
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        let resourcesBefore = renderer.debugWetnessReductionResources

        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "00EB6EE7-13DD-4786-96AF-42796C94C70F")!,
            layerID: bottom.id,
            tool: .water,
            x: 16,
            y: 16
        ))
        try renderer.renderAndWait(stroke: .testDot(
            id: UUID(uuidString: "DAB2E1AF-954F-4365-AC9C-8B52F0A48D3E")!,
            layerID: top.id,
            tool: .water,
            x: 256,
            y: 258
        ))

        let expectedMaximum = try renderer.debugMaximumWetness()
        #expect(abs(renderer.canvasWetness - expectedMaximum) < 0.000_01)
        #expect(renderer.debugWetnessReductionResources == resourcesBefore)
        #expect(resourcesBefore.finalStageThreadgroupCount == 1)
        #expect(
            resourcesBefore.firstStageThreadgroupCount
                < (project.canvas.width * project.canvas.height * PaintingProject.maximumLayerCount) / 32
        )

        try renderer.dry(layerID: bottom.id, steps: 8)
        try renderer.dry(layerID: top.id, steps: 8)
        #expect(renderer.debugWetnessReductionResources == resourcesBefore)
    }

    private func transformedSignature(
        tool: PaintTool,
        project: PaintingProject,
        renderer: WatercolorRenderer
    ) throws -> Int {
        try renderer.replay(project: project)
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, x: 28, y: 32))
        try renderer.render(stroke: .testDot(layerID: project.layers[0].id, tool: tool, x: 36, y: 32))
        return Int((try renderer.debugPixel(x: 38, y: 32).alpha * 100_000).rounded())
    }

    private func depositSignature(
        project: PaintingProject,
        renderer: WatercolorRenderer,
        configure: (inout BrushSettings) -> Void
    ) throws -> Int {
        var stroke = StrokeCommand.testDot(layerID: project.layers[0].id)
        configure(&stroke.brush)
        var replay = project
        replay.commands = [.stroke(stroke)]
        try renderer.replay(project: replay)
        let center = try renderer.debugPixel(x: 32, y: 32).alpha
        let horizontal = try renderer.debugPixel(x: 38, y: 32).alpha
        let vertical = try renderer.debugPixel(x: 32, y: 38).alpha
        return Int(((center + horizontal * 1.7 + vertical * 2.3) * 100_000).rounded())
    }
}

private extension PaintingProject {
    static func testCanvas(_ side: Int, paper: PaperTexture = .coldPress) -> Self {
        Self(
            canvas: CanvasSize(width: side, height: side),
            paper: paper,
            layers: [
                PaintLayer(
                    id: UUID(uuidString: "1F34CEB5-F10B-4AEC-937F-E33603DDCBA2")!,
                    name: "Paint"
                )
            ]
        )
    }
}

private extension StrokeCommand {
    static func testDot(
        id: UUID = UUID(uuidString: "14BB0640-16DC-4432-BD67-AE0CB0991F52")!,
        layerID: UUID,
        tool: PaintTool = .brush,
        pressure: Double = 1,
        color: PaintColor = PaintColor(red: 0.8, green: 0.2, blue: 0.1),
        x: Double = 32,
        y: Double = 32
    ) -> Self {
        Self(
            id: id,
            layerID: layerID,
            tool: tool,
            brush: BrushSettings(
                shape: .round,
                hair: .sable,
                texture: .smooth,
                style: .transparentWash,
                color: color,
                size: 20,
                opacity: 0.8,
                flow: 0.8,
                water: 0.6,
                granulation: 0.2,
                edgeBloom: 0.15
            ),
            points: [StrokePoint(x: x, y: y, pressure: pressure, tiltX: 1, tiltY: 0, time: 0)]
        )
    }

    static func testLine(
        id: UUID = UUID(uuidString: "E0E49930-E802-4BB8-B10E-BAEB740B9BC1")!,
        layerID: UUID,
        color: PaintColor,
        y: Double,
        water: Double
    ) -> Self {
        var brush = testDot(layerID: layerID).brush
        brush.color = color
        brush.water = water
        return Self(
            id: id,
            layerID: layerID,
            tool: .brush,
            brush: brush,
            points: stride(from: 8.0, through: 56.0, by: 4.0).map {
                StrokePoint(x: $0, y: y, pressure: 1, tiltX: 0, tiltY: 0, time: $0)
            }
        )
    }
}

private extension WatercolorRenderer {
    func compositeChecksum() throws -> UInt64 {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The test could not access image bytes")
        }
        return (0..<CFDataGetLength(data)).reduce(UInt64(0)) { checksum, index in
            (checksum &* 16_777_619) ^ UInt64(bytes[index])
        }
    }

    func compositePixel(x: Int, y: Int) throws -> PaintColor {
        let image = try makeCGImage()
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else {
            throw RendererError.readback("The test could not access image bytes")
        }
        let offset = y * image.bytesPerRow + x * 4
        return PaintColor(
            red: Double(bytes[offset + 2]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset]) / 255,
            alpha: Double(bytes[offset + 3]) / 255
        )
    }
}
