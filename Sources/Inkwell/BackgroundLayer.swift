import Foundation
import CoreGraphics

/// A solid-color full-canvas layer. No tiles, no mask, no per-pixel data —
/// just a single `ColorRGBA` plus the standard layer attributes.
///
/// The compositor renders it as one canvas-sized quad with the same
/// blend-mode branching as the tile pipeline. Flatten / save paths
/// special-case it so we don't write any tile bytes for it (the manifest
/// carries only the color).
final class BackgroundLayer: LayerNode {
    let id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: CGFloat = 1.0
    var blendMode: LayerBlendMode = .normal
    var color: ColorRGBA

    init(
        id: UUID = UUID(),
        name: String = "Background",
        color: ColorRGBA = .white
    ) {
        self.id = id
        self.name = name
        self.color = color
    }
}
