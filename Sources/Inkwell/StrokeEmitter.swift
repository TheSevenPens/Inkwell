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

/// Walks the stylus path between samples, placing stamps at fixed canvas-pixel
/// spacing. Per ARCHITECTURE.md decision 11 the path between samples is
/// **Catmull-Rom-smoothed** (centripetal-style with a uniform parameterization,
/// approximated by a polyline), so fast strokes whose samples land sparsely
/// don't appear as polyline segments.
///
/// Drawing has a one-sample lookahead: the segment from `samples[i]` to
/// `samples[i+1]` is drawn only once `samples[i+2]` has arrived, giving us the
/// "future" control point Catmull-Rom needs. The final segment of a stroke is
/// flushed in `end(_:)` with the last sample duplicated as the lookahead.
final class StrokeEmitter {
    let brush: Brush
    private let dispatchStamp: (StylusSample) -> Void
    private let stepLen: CGFloat

    private var samples: [StylusSample] = []
    private var drawnUpTo: Int = 0

    /// Distance to travel along the path before placing the next stamp.
    /// Carried across segments so spacing is continuous over the whole stroke.
    private var nextStampOffset: CGFloat = 0
    private var lastEmittedSample: StylusSample?

    init(brush: Brush, dispatchStamp: @escaping (StylusSample) -> Void) {
        self.brush = brush
        self.dispatchStamp = dispatchStamp
        self.stepLen = max(0.5, brush.spacing * brush.radius * 2.0)
    }

    func begin(_ sample: StylusSample) {
        dispatchStamp(sample)
        samples = [sample]
        drawnUpTo = 0
        nextStampOffset = stepLen
        lastEmittedSample = sample
    }

    func continueTo(_ sample: StylusSample) {
        samples.append(sample)
        // We can draw the segment from samples[i] → samples[i+1] once
        // samples[i+2] has arrived (the future control point). Process every
        // segment that is now drawable.
        while drawnUpTo + 2 < samples.count {
            drawSegment(startIndex: drawnUpTo, hasLookahead: true)
            drawnUpTo += 1
        }
    }

    func end(_ sample: StylusSample) {
        samples.append(sample)
        // Flush remaining segments. The very last segment has no real future
        // sample; we duplicate the endpoint as the ghost lookahead.
        while drawnUpTo + 1 < samples.count {
            let hasLookahead = drawnUpTo + 2 < samples.count
            drawSegment(startIndex: drawnUpTo, hasLookahead: hasLookahead)
            drawnUpTo += 1
        }
        samples = []
        lastEmittedSample = nil
    }

    /// Draw the segment from samples[start] to samples[start+1] as a Catmull-Rom
    /// curve, approximated by a polyline. Uses samples[start-1] (or the start
    /// itself if at the beginning) as the previous control point and
    /// samples[start+2] (or samples[start+1] if at the end of stroke) as the
    /// next control point.
    private func drawSegment(startIndex i: Int, hasLookahead: Bool) {
        let p1 = samples[i]
        let p2 = samples[i + 1]
        let p0: StylusSample = (i > 0) ? samples[i - 1] : p1
        let p3: StylusSample = hasLookahead ? samples[i + 2] : p2

        // Adaptive subdivision based on segment length: more polyline edges for
        // fast strokes (bigger gaps), fewer for slow ones (small gaps).
        let chord = hypot(p2.canvasPoint.x - p1.canvasPoint.x,
                          p2.canvasPoint.y - p1.canvasPoint.y)
        let n = max(4, min(64, Int(chord / max(stepLen, 0.5))))
        let dt: CGFloat = 1.0 / CGFloat(n)

        for stepIndex in 1...n {
            let t = CGFloat(stepIndex) * dt
            let curPoint = catmullRom(p0.canvasPoint, p1.canvasPoint, p2.canvasPoint, p3.canvasPoint, t: t)
            // Stylus parameters interpolate linearly between p1 and p2.
            let curSample = StylusSample(
                canvasPoint: curPoint,
                pressure: p1.pressure + (p2.pressure - p1.pressure) * t,
                tiltX: p1.tiltX + (p2.tiltX - p1.tiltX) * t,
                tiltY: p1.tiltY + (p2.tiltY - p1.tiltY) * t
            )
            walkLinearTo(curSample)
        }
    }

    /// Walk linearly from `lastEmittedSample` to `target`, placing stamps at
    /// `stepLen` along the way. Carries `nextStampOffset` across calls so the
    /// stamp spacing is continuous across polyline edges and segment boundaries.
    private func walkLinearTo(_ target: StylusSample) {
        guard let from = lastEmittedSample else {
            lastEmittedSample = target
            return
        }
        let dx = target.canvasPoint.x - from.canvasPoint.x
        let dy = target.canvasPoint.y - from.canvasPoint.y
        let dist = hypot(dx, dy)
        guard dist > 0 else { return }
        let nx = dx / dist
        let ny = dy / dist
        var travelled = nextStampOffset
        while travelled <= dist {
            let frac = travelled / dist
            let stamp = StylusSample(
                canvasPoint: CGPoint(
                    x: from.canvasPoint.x + nx * travelled,
                    y: from.canvasPoint.y + ny * travelled
                ),
                pressure: from.pressure + (target.pressure - from.pressure) * frac,
                tiltX: from.tiltX + (target.tiltX - from.tiltX) * frac,
                tiltY: from.tiltY + (target.tiltY - from.tiltY) * frac
            )
            dispatchStamp(stamp)
            travelled += stepLen
        }
        nextStampOffset = travelled - dist
        lastEmittedSample = target
    }
}

/// Standard uniform Catmull-Rom interpolation. The curve passes through `p1`
/// at t=0 and `p2` at t=1; `p0` and `p3` shape the tangents.
private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
    let t2 = t * t
    let t3 = t2 * t
    let x = 0.5 * (
        (2.0 * p1.x) +
        (-p0.x + p2.x) * t +
        (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 +
        (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3
    )
    let y = 0.5 * (
        (2.0 * p1.y) +
        (-p0.y + p2.y) * t +
        (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 +
        (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3
    )
    return CGPoint(x: x, y: y)
}
