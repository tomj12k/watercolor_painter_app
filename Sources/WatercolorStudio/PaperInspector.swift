import SwiftUI
import WatercolorCore

struct PaperInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            StudioSectionTitle(title: "Paper")

            Picker("Surface", selection: paperBinding) {
                ForEach(PaperTexture.allCases, id: \.self) { paper in
                    Text(paper.displayName).tag(paper)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!model.canModifyProject)
            .help("Choose the paper fiber used by the watercolor simulation")
        }
        .font(.system(size: 12))
        .tint(StudioPalette.cobalt)
    }

    private var paperBinding: Binding<PaperTexture> {
        Binding(
            get: { model.displayedPaper },
            set: { model.selectPaper($0) }
        )
    }
}

private extension PaperTexture {
    var displayName: String {
        switch self {
        case .hotPress: "Hot press"
        case .coldPress: "Cold press"
        case .rough: "Rough"
        case .handmade: "Handmade"
        case .canvas: "Canvas"
        }
    }
}
