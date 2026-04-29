import Foundation
import CoreGraphics

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
