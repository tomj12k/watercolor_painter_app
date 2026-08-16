import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import WatercolorCore
@testable import WatercolorEngine

struct BrushMatrixExportResult {
    let sectionCount: Int
    let sampleCount: Int
    let nonemptySampleCount: Int
    let width: Int
    let height: Int
}

@MainActor enum BrushMatrixExporter {
    private static let canvasWidth = 160
    private static let canvasHeight = 120
    private static let labelWidth = 140
    private static let cellWidth = 174
    private static let rowHeight = 190
    private static let headerHeight = 54

    static func export(to outputURL: URL, device: MTLDevice) throws -> BrushMatrixExportResult {
        let sections = matrixSections
        let width = labelWidth + cellWidth * 5
        let height = headerHeight + rowHeight * sections.count
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrushMatrixExportError.couldNotCreateCanvas
        }

        context.setFillColor(CGColor(srgbRed: 0.955, green: 0.935, blue: 0.885, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(
            "Watercolor Studio — deterministic brush matrix",
            at: CGPoint(x: 18, y: height - 36),
            fontSize: 20,
            color: CGColor(srgbRed: 0.12, green: 0.11, blue: 0.09, alpha: 1),
            context: context
        )

        var sampleIndex = 0
        var nonemptySampleCount = 0
        for (sectionIndex, section) in sections.enumerated() {
            let rowTop = height - headerHeight - sectionIndex * rowHeight
            drawText(
                section.title,
                at: CGPoint(x: 18, y: rowTop - 82),
                fontSize: 17,
                color: CGColor(srgbRed: 0.19, green: 0.24, blue: 0.25, alpha: 1),
                context: context
            )
            drawText(
                section.subtitle,
                at: CGPoint(x: 18, y: rowTop - 103),
                fontSize: 10,
                color: CGColor(srgbRed: 0.32, green: 0.34, blue: 0.31, alpha: 1),
                context: context
            )

            for (column, variant) in section.variants.enumerated() {
                let sample = try render(variant: variant, sampleIndex: sampleIndex, device: device)
                if sample.metrics.area > 0, sample.metrics.pigmentMass > 0 {
                    nonemptySampleCount += 1
                }
                let cellX = labelWidth + column * cellWidth
                let imageY = rowTop - 151
                drawText(
                    variant.displayName,
                    at: CGPoint(x: cellX + 4, y: rowTop - 22),
                    fontSize: 13,
                    color: CGColor(srgbRed: 0.12, green: 0.11, blue: 0.09, alpha: 1),
                    context: context
                )
                context.saveGState()
                context.translateBy(x: CGFloat(cellX + 4), y: CGFloat(imageY + canvasHeight))
                context.scaleBy(x: 1, y: -1)
                context.draw(
                    sample.image,
                    in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
                )
                context.restoreGState()
                drawText(
                    metricCaption(sample.metrics),
                    at: CGPoint(x: cellX + 4, y: rowTop - 174),
                    fontSize: 9,
                    color: CGColor(srgbRed: 0.29, green: 0.27, blue: 0.23, alpha: 1),
                    context: context
                )
                sampleIndex += 1
            }
        }

        guard let image = context.makeImage() else {
            throw BrushMatrixExportError.couldNotCreateImage
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw BrushMatrixExportError.couldNotCreateDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BrushMatrixExportError.couldNotWriteImage
        }
        print("Brush matrix written to \(outputURL.path)")

        return BrushMatrixExportResult(
            sectionCount: sections.count,
            sampleCount: sampleIndex,
            nonemptySampleCount: nonemptySampleCount,
            width: width,
            height: height
        )
    }

    private static func render(
        variant: BrushMatrixVariant,
        sampleIndex: Int,
        device: MTLDevice
    ) throws -> BrushMatrixSample {
        let layer = PaintLayer(
            id: UUID(uuidString: "9D379134-29D9-4244-8377-A00C9189A67C")!,
            name: "Matrix"
        )
        let project = PaintingProject(
            canvas: CanvasSize(width: canvasWidth, height: canvasHeight),
            paper: .rough,
            layers: [layer]
        )
        var brush = BrushSettings.default
        brush.shape = .round
        brush.hair = .sable
        brush.texture = .smooth
        brush.style = .transparentWash
        brush.color = variant.sectionColor
        brush.size = 28
        brush.opacity = 0.86
        brush.flow = 0.82
        brush.water = 0.72
        brush.granulation = 0.55
        brush.edgeBloom = 0.5
        brush.behaviorVersion = 1
        brush.spacing = 0.18
        brush.bristleStrength = 1
        brush.textureStrength = 1
        variant.apply(to: &brush)

        let stroke = StrokeCommand(
            id: deterministicStrokeID(sampleIndex),
            layerID: layer.id,
            tool: .brush,
            brush: brush,
            points: (0..<9).map { index in
                StrokePoint(
                    x: Double(24 + index * 14),
                    y: 60 + sin(Double(index) * .pi / 8) * 7,
                    pressure: 0.9,
                    tiltX: 0,
                    tiltY: 0,
                    time: Double(index) / 60
                )
            }
        )
        let renderer = try WatercolorRenderer(project: project, device: device)
        try renderer.renderAndWait(stroke: stroke)
        try renderer.dry(layerID: layer.id, steps: 4)
        let fields = try renderer.debugLayerFields(layerID: layer.id)
        return BrushMatrixSample(
            image: try renderer.makeCGImage(),
            metrics: BrushPhenotypeMetrics.measure(fields)
        )
    }

    private static func deterministicStrokeID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "6B26065D-F18A-4000-8000-%012X", index + 1))!
    }

    private static func metricCaption(_ metrics: BrushPhenotypeMetrics) -> String {
        String(
            format: "area %.0f · lanes %d · void %.2f",
            metrics.area,
            metrics.laneCount,
            metrics.voidRatio
        )
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        context: CGContext
    ) {
        let font = CTFontCreateWithName("Avenir Next" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        )
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static let matrixSections = [
        BrushMatrixSection(
            title: "Shape",
            subtitle: "footprint + direction",
            variants: BrushShape.allCases.map(BrushMatrixVariant.shape)
        ),
        BrushMatrixSection(
            title: "Hair",
            subtitle: "water + bristle character",
            variants: BrushHair.allCases.map(BrushMatrixVariant.hair)
        ),
        BrushMatrixSection(
            title: "Texture",
            subtitle: "paper + pigment breakup",
            variants: BrushTexture.allCases.map(BrushMatrixVariant.texture)
        ),
        BrushMatrixSection(
            title: "Style",
            subtitle: "deposition + diffusion",
            variants: WatercolorStyle.allCases.map(BrushMatrixVariant.style)
        )
    ]
}

private struct BrushMatrixSection {
    let title: String
    let subtitle: String
    let variants: [BrushMatrixVariant]
}

private struct BrushMatrixSample {
    let image: CGImage
    let metrics: BrushPhenotypeMetrics
}

private enum BrushMatrixVariant {
    case shape(BrushShape)
    case hair(BrushHair)
    case texture(BrushTexture)
    case style(WatercolorStyle)

    var displayName: String {
        switch self {
        case let .shape(value): return value.artistName
        case let .hair(value): return value.artistName
        case let .texture(value): return value.artistName
        case let .style(value): return value.artistName
        }
    }

    var sectionColor: PaintColor {
        switch self {
        case .shape: return .fromSRGB(red: 0.12, green: 0.42, blue: 0.58)
        case .hair: return .fromSRGB(red: 0.47, green: 0.24, blue: 0.16)
        case .texture: return .fromSRGB(red: 0.30, green: 0.42, blue: 0.20)
        case .style: return .fromSRGB(red: 0.48, green: 0.18, blue: 0.42)
        }
    }

    func apply(to brush: inout BrushSettings) {
        switch self {
        case let .shape(value): brush.shape = value
        case let .hair(value): brush.hair = value
        case let .texture(value): brush.texture = value
        case let .style(value): brush.style = value
        }
    }
}

private extension BrushShape {
    var artistName: String { rawValue.capitalized }
}

private extension BrushHair {
    var artistName: String { rawValue.capitalized }
}

private extension BrushTexture {
    var artistName: String { rawValue.capitalized }
}

private extension WatercolorStyle {
    var artistName: String {
        switch self {
        case .transparentWash: return "Transparent Wash"
        case .wetOnWet: return "Wet-on-Wet"
        case .dryBrush: return "Dry Brush"
        case .glazing: return "Glazing"
        case .bloom: return "Bloom"
        }
    }
}

private enum BrushMatrixExportError: Error {
    case couldNotCreateCanvas
    case couldNotCreateImage
    case couldNotCreateDestination
    case couldNotWriteImage
}
