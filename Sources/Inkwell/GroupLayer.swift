import Foundation
import CoreGraphics

/// A layer group: a tree node holding child layers. Phase 4 ships pass-through
/// groups — group opacity multiplies down through children, but group blend
/// mode is not isolated. Isolated group compositing arrives in a later phase
/// (see FUTURES.md "Group masks" and a future "isolated groups" item).
final class GroupLayer: LayerNode {
    let id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: CGFloat = 1.0
    var blendMode: LayerBlendMode = .normal
    var isExpanded: Bool = true

    var children: [LayerNode] = []

    init(id: UUID = UUID(), name: String = "Group") {
        self.id = id
        self.name = name
    }
}
