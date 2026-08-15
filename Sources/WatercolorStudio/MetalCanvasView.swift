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
        return view
    }

    public func updateNSView(_ view: CanvasEventView, context: Context) {
        view.synchronize(with: model)
    }
}
