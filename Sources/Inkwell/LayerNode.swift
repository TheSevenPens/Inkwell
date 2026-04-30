import Foundation
import CoreGraphics
import Metal

/// Per ARCHITECTURE.md decision 5 commitment 1: a sum type for layers.
/// Bitmap layers and groups are siblings; future vector / text / adjustment
/// layers slot in as new conformers without disturbing the tree machinery.
protocol LayerNode: AnyObject {
    var id: UUID { get }
    var name: String { get set }
    var isVisible: Bool { get set }
    var opacity: CGFloat { get set }
    var blendMode: LayerBlendMode { get set }
}

/// Layers that present a sparse grid of GPU tiles to the compositor.
/// BitmapLayer is the canonical conformer; VectorLayer caches its rasterized
/// strokes into the same tile structure so the compositor doesn't need to know
/// which kind it's drawing.
protocol CompositableLayer: LayerNode {
    var canvasWidth: Int { get }
    var canvasHeight: Int { get }
    var mask: LayerMask? { get }
    func tile(at coord: TileCoord) -> (any MTLTexture)?
    func tilesIntersecting(_ rect: CGRect) -> [TileCoord]
    func canvasRect(for coord: TileCoord) -> CGRect
    func allTiles() -> [(coord: TileCoord, texture: any MTLTexture)]
    func readTileBytes(_ texture: any MTLTexture) -> Data
}

/// Phase 4 blend mode set. Phase 9 expands to the full Photoshop set with the
/// PSD fidelity table per ARCHITECTURE.md decision 14.
enum LayerBlendMode: String, CaseIterable, Codable, Equatable {
    case normal
    case multiply
    case screen
    case overlay

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        }
    }

    /// Index used as a uniform value for the compositor's branch selector.
    var shaderIndex: Int32 {
        switch self {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        }
    }
}
