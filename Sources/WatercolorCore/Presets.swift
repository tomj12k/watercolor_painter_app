public extension BrushSettings {
    /// Returns these settings with the deterministic parameters for `preset` applied.
    /// Brush identity and color remain unchanged when a style is selected.
    func applying(_ preset: WatercolorStyle) -> Self {
        let parameters: (opacity: Double, flow: Double, water: Double, granulation: Double, edgeBloom: Double)

        switch preset {
        case .transparentWash:
            parameters = (0.35, 0.4, 0.6, 0.2, 0.15)
        case .wetOnWet:
            parameters = (0.3, 0.5, 0.9, 0.3, 0.8)
        case .dryBrush:
            parameters = (0.6, 0.25, 0.1, 0.6, 0.05)
        case .glazing:
            parameters = (0.25, 0.3, 0.35, 0.25, 0.1)
        case .bloom:
            parameters = (0.4, 0.55, 0.85, 0.25, 0.95)
        }

        var result = self
        result.style = preset
        result.opacity = parameters.opacity
        result.flow = parameters.flow
        result.water = parameters.water
        result.granulation = parameters.granulation
        result.edgeBloom = parameters.edgeBloom
        return result
    }
}
