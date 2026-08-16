import SwiftUI
import WatercolorCore

enum NewCanvasPreset: String, CaseIterable, Identifiable, Sendable {
    case landscape
    case portrait
    case square

    var id: Self { self }

    var title: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        }
    }

    var canvas: CanvasSize {
        switch self {
        case .landscape: CanvasSize(width: 1600, height: 1200)
        case .portrait: CanvasSize(width: 1200, height: 1600)
        case .square: CanvasSize(width: 2048, height: 2048)
        }
    }
}

enum NewCanvasConfigurationError: LocalizedError, Equatable {
    case unsupportedWidth(Int)
    case unsupportedHeight(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedWidth(width):
            "Canvas width must be between 256 and 4096 pixels (received \(width))."
        case let .unsupportedHeight(height):
            "Canvas height must be between 256 and 4096 pixels (received \(height))."
        }
    }
}

struct NewCanvasConfiguration: Equatable, Sendable {
    static let dimensionRange = 256...4096

    var width: Int
    var height: Int
    var paper: PaperTexture

    var canvas: CanvasSize {
        CanvasSize(width: width, height: height)
    }

    init(width: Int, height: Int, paper: PaperTexture) {
        self.width = width
        self.height = height
        self.paper = paper
    }

    init(preset: NewCanvasPreset, paper: PaperTexture = .coldPress) {
        width = preset.canvas.width
        height = preset.canvas.height
        self.paper = paper
    }

    func makeProject() throws -> PaintingProject {
        guard Self.dimensionRange.contains(width) else {
            throw NewCanvasConfigurationError.unsupportedWidth(width)
        }
        guard Self.dimensionRange.contains(height) else {
            throw NewCanvasConfigurationError.unsupportedHeight(height)
        }
        var project = PaintingProject.newDefault()
        project.canvas = canvas
        project.paper = paper
        try project.validate()
        return project
    }
}

struct NewCanvasConfigurationView: View {
    var failure: StudioFailure? = nil
    var copyDetails: (StudioFailure) -> Void = { _ in }
    var dismissFailure: () -> Void = {}
    let create: (NewCanvasConfiguration) -> Void
    let useDefault: () -> Void

    @State private var width = NewCanvasPreset.landscape.canvas.width
    @State private var height = NewCanvasPreset.landscape.canvas.height
    @State private var paper = PaperTexture.coldPress

    private var configuration: NewCanvasConfiguration {
        NewCanvasConfiguration(width: width, height: height, paper: paper)
    }

    private var isValid: Bool {
        NewCanvasConfiguration.dimensionRange.contains(width)
            && NewCanvasConfiguration.dimensionRange.contains(height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Watercolor")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            Text("Choose a useful starting size or enter a custom canvas from 256 to 4096 pixels.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(NewCanvasPreset.allCases) { preset in
                    Button {
                        width = preset.canvas.width
                        height = preset.canvas.height
                    } label: {
                        VStack(spacing: 3) {
                            Text(preset.title)
                            Text("\(preset.canvas.width) × \(preset.canvas.height)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: $width, format: .number)
                        .frame(width: 110)
                    Stepper("Width", value: $width, in: NewCanvasConfiguration.dimensionRange)
                        .labelsHidden()
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: $height, format: .number)
                        .frame(width: 110)
                    Stepper("Height", value: $height, in: NewCanvasConfiguration.dimensionRange)
                        .labelsHidden()
                }
                GridRow {
                    Text("Paper")
                    Picker("Paper", selection: $paper) {
                        ForEach(PaperTexture.allCases, id: \.self) { texture in
                            Text(texture.newCanvasTitle).tag(texture)
                        }
                    }
                    .labelsHidden()
                    .gridCellColumns(2)
                }
            }

            if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text(failure.recoverySuggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Try Again") { create(configuration) }
                        Button("Copy Details") { copyDetails(failure) }
                        Button("Dismiss", action: dismissFailure)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Canvas creation issue")
                .accessibilityIdentifier("new-watercolor-failure")
            }

            HStack {
                Button("Use Default", action: useDefault)
                    .accessibilityLabel("Use Default Canvas")
                    .accessibilityIdentifier("new-watercolor-use-default")
                Spacer()
                Button("Create") { create(configuration) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                    .accessibilityLabel("Create Watercolor Canvas")
                    .accessibilityIdentifier("new-watercolor-create")
            }
        }
        .padding(24)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Watercolor")
        .accessibilityIdentifier("new-watercolor-configuration")
        .interactiveDismissDisabled()
    }
}

private extension PaperTexture {
    var newCanvasTitle: String {
        switch self {
        case .hotPress: "Hot press"
        case .coldPress: "Cold press"
        case .rough: "Rough"
        case .handmade: "Handmade"
        case .canvas: "Canvas"
        }
    }
}
