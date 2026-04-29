import Foundation
import CoreGraphics

/// Phase 2: walks along the stylus path, dispatching stamp positions through a closure.
/// The closure performs the GPU stamp and tracks dirty tiles for undo.
final class StrokeEmitter {
    let brush: Brush
    private let dispatchStamp: (CGPoint) -> Void

    private var lastPoint: CGPoint?
    private var nextStampOffset: CGFloat = 0
    private let stepLen: CGFloat

    init(brush: Brush, dispatchStamp: @escaping (CGPoint) -> Void) {
        self.brush = brush
        self.dispatchStamp = dispatchStamp
        self.stepLen = max(0.5, brush.spacing * brush.radius * 2.0)
    }

    func begin(at point: CGPoint) {
        dispatchStamp(point)
        lastPoint = point
        nextStampOffset = stepLen
    }

    func continueTo(_ point: CGPoint) {
        guard let from = lastPoint else { return }
        let dx = point.x - from.x
        let dy = point.y - from.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { return }
        let nx = dx / dist
        let ny = dy / dist
        var travelled = nextStampOffset
        while travelled <= dist {
            let p = CGPoint(x: from.x + nx * travelled, y: from.y + ny * travelled)
            dispatchStamp(p)
            travelled += stepLen
        }
        nextStampOffset = travelled - dist
        lastPoint = point
    }

    func end(at point: CGPoint) {
        continueTo(point)
        lastPoint = nil
    }
}
