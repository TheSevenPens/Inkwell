import Foundation
import CoreGraphics

/// Phase 1: walks along the stylus path and places stamps at fixed spacing.
/// No pressure mapping yet (per PLAN.md Phase 1 scope) — fixed alpha and radius.
final class StrokeEmitter {
    // Note: stamping mutates BitmapCanvas state. AppKit guarantees mouse / stylus
    // events arrive on the main thread, so this class is implicitly main-thread only
    // for Phase 1. Phase 8 will introduce a dedicated stroke thread per ARCHITECTURE
    // decision 8.
    let brush: Brush
    let stamp: CGImage
    private weak var canvas: BitmapCanvas?

    private var lastPoint: CGPoint?
    private var nextStampOffset: CGFloat = 0
    private var stepLen: CGFloat

    init(brush: Brush, stamp: CGImage, canvas: BitmapCanvas) {
        self.brush = brush
        self.stamp = stamp
        self.canvas = canvas
        self.stepLen = max(0.5, brush.spacing * brush.radius * 2.0)
    }

    func begin(at point: CGPoint) {
        guard let canvas else { return }
        canvas.stamp(stamp, at: point, alpha: brush.opacity)
        lastPoint = point
        nextStampOffset = stepLen
    }

    func continueTo(_ point: CGPoint) {
        guard let canvas, let from = lastPoint else { return }
        let dx = point.x - from.x
        let dy = point.y - from.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { return }
        let nx = dx / dist
        let ny = dy / dist

        var travelled = nextStampOffset
        while travelled <= dist {
            let p = CGPoint(x: from.x + nx * travelled, y: from.y + ny * travelled)
            canvas.stamp(stamp, at: p, alpha: brush.opacity)
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
