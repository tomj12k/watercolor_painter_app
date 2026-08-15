import SwiftUI

@MainActor
public struct MetalCanvasView: NSViewRepresentable {
    @ObservedObject private var model: StudioModel

    public init(model: StudioModel) {
        self.model = model
    }

    public func makeNSView(context: Context) -> CanvasEventView {
        let view = CanvasEventView(model: model)
        model.configureCanvas(view)
        view.needsDisplay = true
        return view
    }

    public func updateNSView(_ view: CanvasEventView, context: Context) {
        model.configureCanvas(view)
        view.synchronize(with: model)
    }
}
