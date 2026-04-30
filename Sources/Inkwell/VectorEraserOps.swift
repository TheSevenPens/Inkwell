import Foundation
import CoreGraphics

/// Algorithms backing the three vector eraser modes (`VectorEraserMode`).
/// Pure functions on `VectorStroke`s — no AppKit / Metal / state.
///
/// Each mode is implemented as a `(stroke, …) -> [VectorStroke]` function
/// that returns the *replacement* strokes for the input stroke. Returning
/// an empty array means the input stroke is fully erased; returning N items
/// means it splits into N sub-strokes.
enum VectorEraserOps {

    // MARK: - Mode 2 — touched region

    /// Split `stroke` at the samples that fall inside the eraser disc. Each
    /// run of consecutive *outside* samples (≥ 2 samples) becomes a new
    /// sub-stroke. Single-sample runs are dropped because a single sample
    /// renders only as a degenerate disk, which the user typically also
    /// wants gone alongside its erased neighbours.
    static func splitAtTouchedSamples(
        _ stroke: VectorStroke,
        center: CGPoint,
        radius: CGFloat
    ) -> [VectorStroke] {
        var runs: [[VectorStrokeSample]] = []
        var current: [VectorStrokeSample] = []
        for s in stroke.samples {
            let strokeR = stroke.radius(forPressure: s.pressure)
            let dx = s.x - center.x
            let dy = s.y - center.y
            let inside = (dx * dx + dy * dy) <= (radius + strokeR) * (radius + strokeR)
            if inside {
                if current.count >= 2 { runs.append(current) }
                current = []
            } else {
                current.append(s)
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs.map { samples in
            VectorStroke(
                kind: stroke.kind,
                color: stroke.color,
                opacity: stroke.opacity,
                maxRadius: stroke.maxRadius,
                minRadius: stroke.minRadius,
                samples: samples
            )
        }
    }

    // MARK: - Mode 3 — to intersection

    /// From the closest sample on `stroke` to the eraser center, walk
    /// forward and backward until a segment of the stroke crosses either:
    /// - a non-adjacent segment of the same stroke (self-intersection), or
    /// - any segment of any stroke in `others`.
    ///
    /// The run between the two stop points is removed; up to two sub-strokes
    /// remain. If no intersection is found in a direction, that side runs
    /// to the end of the stroke (so the stroke is trimmed up to its tip).
    static func cutToIntersection(
        _ stroke: VectorStroke,
        strokeIndex: Int,
        center: CGPoint,
        radius: CGFloat,
        allStrokes: [VectorStroke]
    ) -> [VectorStroke] {
        let samples = stroke.samples
        guard samples.count >= 2 else { return [] }

        // Pick the cut sample: the sample closest to the eraser center.
        var cutIndex = 0
        var bestDistSq = CGFloat.infinity
        for (i, s) in samples.enumerated() {
            let dx = s.x - center.x
            let dy = s.y - center.y
            let dsq = dx * dx + dy * dy
            if dsq < bestDistSq {
                bestDistSq = dsq
                cutIndex = i
            }
        }

        // Walk forward: find the smallest segment index >= cutIndex whose
        // segment crosses something. The cut keeps samples 0...endIndex
        // up to (and including) the segment's start sample.
        let lastSegIndex = samples.count - 2  // segment i goes samples[i] -> samples[i+1]
        var forwardSegHit: Int? = nil
        if cutIndex <= lastSegIndex {
            for i in cutIndex...lastSegIndex {
                if segmentCrossesAny(stroke: stroke, segIndex: i,
                                     ownIndex: strokeIndex, allStrokes: allStrokes) {
                    forwardSegHit = i
                    break
                }
            }
        }

        // Walk backward: find the largest segment index < cutIndex whose
        // segment crosses something.
        var backwardSegHit: Int? = nil
        if cutIndex > 0 {
            for i in stride(from: cutIndex - 1, through: 0, by: -1) {
                if segmentCrossesAny(stroke: stroke, segIndex: i,
                                     ownIndex: strokeIndex, allStrokes: allStrokes) {
                    backwardSegHit = i
                    break
                }
            }
        }

        // Determine sample ranges to keep.
        // Backward keeps samples[0 ... backwardKeepEnd]; nil = no backward keep.
        // Forward keeps samples[forwardKeepStart ... last]; nil = no forward keep.
        let backwardKeepEnd: Int? = backwardSegHit  // sample at end of crossing segment's start
        let forwardKeepStart: Int? = forwardSegHit.map { $0 + 1 }  // sample after crossing segment's start

        var result: [VectorStroke] = []
        if let end = backwardKeepEnd, end >= 1 {
            let kept = Array(samples[0 ... end])
            if kept.count >= 2 {
                result.append(rebuild(stroke, samples: kept))
            }
        }
        if let start = forwardKeepStart, start <= samples.count - 2 {
            let kept = Array(samples[start ..< samples.count])
            if kept.count >= 2 {
                result.append(rebuild(stroke, samples: kept))
            }
        }
        return result
    }

    /// Does segment `segIndex` of `stroke` cross any non-adjacent segment of
    /// the same stroke, or any segment of any *other* stroke in `allStrokes`?
    private static func segmentCrossesAny(
        stroke: VectorStroke,
        segIndex i: Int,
        ownIndex: Int,
        allStrokes: [VectorStroke]
    ) -> Bool {
        let samples = stroke.samples
        let a = CGPoint(x: samples[i].x, y: samples[i].y)
        let b = CGPoint(x: samples[i + 1].x, y: samples[i + 1].y)

        // Self-intersection (non-adjacent only).
        for j in 0..<(samples.count - 1) {
            if abs(j - i) <= 1 { continue }  // adjacent segments share a vertex
            let c = CGPoint(x: samples[j].x, y: samples[j].y)
            let d = CGPoint(x: samples[j + 1].x, y: samples[j + 1].y)
            if segmentsIntersect(a, b, c, d) { return true }
        }
        // Cross-stroke intersection.
        for (idx, other) in allStrokes.enumerated() {
            if idx == ownIndex { continue }
            let oSamples = other.samples
            if oSamples.count < 2 { continue }
            // bbox cull for speed
            let segMinX = min(a.x, b.x), segMaxX = max(a.x, b.x)
            let segMinY = min(a.y, b.y), segMaxY = max(a.y, b.y)
            if segMaxX < other.bounds.minX || segMinX > other.bounds.maxX { continue }
            if segMaxY < other.bounds.minY || segMinY > other.bounds.maxY { continue }
            for j in 0..<(oSamples.count - 1) {
                let c = CGPoint(x: oSamples[j].x, y: oSamples[j].y)
                let d = CGPoint(x: oSamples[j + 1].x, y: oSamples[j + 1].y)
                if segmentsIntersect(a, b, c, d) { return true }
            }
        }
        return false
    }

    private static func rebuild(_ template: VectorStroke, samples: [VectorStrokeSample]) -> VectorStroke {
        VectorStroke(
            kind: template.kind,
            color: template.color,
            opacity: template.opacity,
            maxRadius: template.maxRadius,
            minRadius: template.minRadius,
            samples: samples
        )
    }
}

/// Standard CCW-based segment intersection. Treats collinear / touching
/// cases as non-intersecting (good enough for the vector eraser; sample
/// quantization makes exact collinearity vanishingly rare in practice).
private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
    func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    let d1 = ccw(p3, p4, p1)
    let d2 = ccw(p3, p4, p2)
    let d3 = ccw(p1, p2, p3)
    let d4 = ccw(p1, p2, p4)
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
        && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}
