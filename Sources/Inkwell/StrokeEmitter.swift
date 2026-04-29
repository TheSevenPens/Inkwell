import Foundation
import CoreGraphics

/// One stylus / mouse sample's worth of input parameters.
struct StylusSample {
    var canvasPoint: CGPoint
    var pressure: CGFloat   // 0..1 (mouse defaults to 1.0)
    var tiltX: CGFloat      // -1..1; 0 if not stylus
    var tiltY: CGFloat      // -1..1; 0 if not stylus

    static func mouseAt(_ point: CGPoint) -> StylusSample {
        StylusSample(canvasPoint: point, pressure: 1.0, tiltX: 0, tiltY: 0)
    }
}

/// Phase 3: walks along the stylus path between samples, dispatching stamp positions.
/// Per-stamp parameters (size, alpha, angle) are linearly interpolated between the
/// segment's endpoints — the dispatcher resolves brush-specific modulation.
final class StrokeEmitter {
    let brush: Brush
    private let dispatchStamp: (StylusSample) -> Void

    private var lastSample: StylusSample?
    private var nextStampOffset: CGFloat = 0
    private let stepLen: CGFloat

    init(brush: Brush, dispatchStamp: @escaping (StylusSample) -> Void) {
        self.brush = brush
        self.dispatchStamp = dispatchStamp
        self.stepLen = max(0.5, brush.spacing * brush.radius * 2.0)
    }

    func begin(_ sample: StylusSample) {
        dispatchStamp(sample)
        lastSample = sample
        nextStampOffset = stepLen
    }

    func continueTo(_ sample: StylusSample) {
        guard let from = lastSample else { return }
        let dx = sample.canvasPoint.x - from.canvasPoint.x
        let dy = sample.canvasPoint.y - from.canvasPoint.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { return }
        let nx = dx / dist
        let ny = dy / dist
        var travelled = nextStampOffset
        while travelled <= dist {
            let t = travelled / dist
            let interp = StylusSample(
                canvasPoint: CGPoint(
                    x: from.canvasPoint.x + nx * travelled,
                    y: from.canvasPoint.y + ny * travelled
                ),
                pressure: from.pressure + (sample.pressure - from.pressure) * t,
                tiltX: from.tiltX + (sample.tiltX - from.tiltX) * t,
                tiltY: from.tiltY + (sample.tiltY - from.tiltY) * t
            )
            dispatchStamp(interp)
            travelled += stepLen
        }
        nextStampOffset = travelled - dist
        lastSample = sample
    }

    func end(_ sample: StylusSample) {
        continueTo(sample)
        lastSample = nil
    }
}
