import Foundation
import Metal
import WatercolorCore

public struct StudioDiagnostic: Equatable, Sendable {
    public let appVersion: String
    public let operatingSystem: String
    public let gpuName: String
    public let canvasWidth: Int?
    public let canvasHeight: Int?
    public let layerCount: Int?
    public let commandCount: Int?
    public let errorCode: String

    public init(
        appVersion: String,
        operatingSystem: String,
        gpuName: String,
        canvasWidth: Int?,
        canvasHeight: Int?,
        layerCount: Int?,
        commandCount: Int?,
        errorCode: String
    ) {
        self.appVersion = appVersion
        self.operatingSystem = operatingSystem
        self.gpuName = gpuName
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.layerCount = layerCount
        self.commandCount = commandCount
        self.errorCode = errorCode
    }

    public var customerText: String {
        var lines = [
            "Watercolor Studio diagnostics",
            "App: \(appVersion)",
            "OS: \(operatingSystem)",
            "GPU: \(gpuName)"
        ]
        if let canvasWidth, let canvasHeight {
            lines.append("Canvas: \(canvasWidth) × \(canvasHeight)")
        } else {
            lines.append("Canvas: unavailable")
        }
        lines.append("Layers: \(layerCount.map(String.init) ?? "unavailable")")
        lines.append("Commands: \(commandCount.map(String.init) ?? "unavailable")")
        lines.append("Error code: \(errorCode)")
        return lines.joined(separator: "\n")
    }

    static func live(errorCode: String, project: PaintingProject?) -> Self {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String
        let appVersion = build.map { "\(version) (\($0))" } ?? version
        return Self(
            appVersion: appVersion,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            gpuName: MTLCreateSystemDefaultDevice()?.name ?? "Unavailable",
            canvasWidth: project?.canvas.width,
            canvasHeight: project?.canvas.height,
            layerCount: project?.layers.count,
            commandCount: project?.commands.count,
            errorCode: errorCode
        )
    }
}
