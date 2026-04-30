import Foundation
import CoreGraphics

/// Builds a vector stroke incrementally as stylus samples arrive.
///
/// Mirrors `StrokeEmitter`'s Catmull-Rom-with-lookahead pattern: a segment from
/// raw_sample[i] → raw_sample[i+1] is densified once raw_sample[i+2] has
/// arrived (so the curve through raw_sample[i+1] has both shaping neighbours
/// available). Each densified mini-segment is rendered immediately for live
/// preview via the supplied `drawSegment` closure.
///
/// On `end(_:)`, the final segment is flushed (with the endpoint duplicated as
/// the ghost lookahead) and the closure-emitted dense polyline matches what
/// `StrokeRibbonRenderer.densify` would produce from the raw samples — so a
/// post-commit re-rasterization (e.g. on undo / save / load) replays the same
/// pixels.
final class VectorStrokeBuilder {
    typealias DrawSegment = (
        _ from: CGPoint, _ ra: CGFloat,
        _ to: CGPoint, _ rb: CGFloat
    ) -> Void

    private(set) var samples: [VectorStrokeSample] = []
    private var drawnUpTo: Int = 0

    /// Last dense polyline point we drew to. Each new mini-segment is drawn
    /// from this point to the next densified point, then this is updated.
    private var lastDensePoint: (CGPoint, CGFloat)?

    let minRadius: CGFloat
    let maxRadius: CGFloat
    private let drawSegment: DrawSegment

    init(minRadius: CGFloat, maxRadius: CGFloat, drawSegment: @escaping DrawSegment) {
        self.minRadius = minRadius
        self.maxRadius = maxRadius
        self.drawSegment = drawSegment
    }

    private func radius(forPressure p: CGFloat) -> CGFloat {
        let pp = max(0, min(1, p))
        return minRadius + (maxRadius - minRadius) * pp
    }

    func begin(_ sample: VectorStrokeSample) {
        samples = [sample]
        drawnUpTo = 0
        // Seed lastDensePoint to the first raw sample so the first emitted
        // mini-segment connects from there. We don't emit anything yet — the
        // first emit happens inside `renderRawSegment` once the next raw
        // sample arrives. This precisely matches `StrokeRibbonRenderer.densify`'s
        // output, so committed-stroke re-rasterization produces identical pixels.
        let r = radius(forPressure: sample.pressure)
        lastDensePoint = (sample.point, r)
    }

    func continueTo(_ sample: VectorStrokeSample) {
        samples.append(sample)
        while drawnUpTo + 2 < samples.count {
            renderRawSegment(startIndex: drawnUpTo, hasLookahead: true)
            drawnUpTo += 1
        }
    }

    func end(_ sample: VectorStrokeSample) {
        samples.append(sample)
        while drawnUpTo + 1 < samples.count {
            let hasLookahead = drawnUpTo + 2 < samples.count
            renderRawSegment(startIndex: drawnUpTo, hasLookahead: hasLookahead)
            drawnUpTo += 1
        }
    }

    /// Densify the segment from raw samples[i] → samples[i+1] using
    /// Catmull-Rom and emit each mini-segment to the draw closure.
    /// Mirrors `StrokeRibbonRenderer.densify`'s per-segment logic so the
    /// committed-stroke re-rasterization produces the same pixels.
    private func renderRawSegment(startIndex i: Int, hasLookahead: Bool) {
        let p1 = samples[i]
        let p2 = samples[i + 1]
        let p0: VectorStrokeSample = (i > 0) ? samples[i - 1] : p1
        let p3: VectorStrokeSample = hasLookahead ? samples[i + 2] : p2

        let chord = hypot(p2.x - p1.x, p2.y - p1.y)
        let n = max(4, min(64, Int(chord / 2.0)))

        for step in 1...n {
            let t = CGFloat(step) / CGFloat(n)
            let pt = catmullRom(p0.point, p1.point, p2.point, p3.point, t: t)
            let pressure = p1.pressure + (p2.pressure - p1.pressure) * t
            let r = radius(forPressure: pressure)
            if let prev = lastDensePoint {
                drawSegment(prev.0, prev.1, pt, r)
            }
            lastDensePoint = (pt, r)
        }
    }
}

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
