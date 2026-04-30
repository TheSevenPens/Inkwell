import Foundation
import CoreGraphics

private func distanceFromPointToSegment(p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
    let abx = b.x - a.x
    let aby = b.y - a.y
    let lenSq = abx * abx + aby * aby
    if lenSq < 1e-9 {
        return hypot(p.x - a.x, p.y - a.y)
    }
    let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq))
    let cx = a.x + t * abx
    let cy = a.y + t * aby
    return hypot(p.x - cx, p.y - cy)
}

/// A single stylus sample stored on a vector stroke. Position is in canvas
/// pixels. Pressure is normalized 0…1.
struct VectorStrokeSample: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat

    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// A vector stroke: a brush snapshot plus the polyline of stylus samples that
/// drew it. Authoritative source — the layer's tile cache is derived by
/// re-rasterizing this list with `StrokeRibbonRenderer`.
///
/// V1 only supports G-Pen-style strokes: hard edges, pressure modulates
/// radius, opacity is constant per stroke. Other brush shapes will need
/// different shaders (Marker = soft falloff, Airbrush = density splat, etc.)
/// and are deferred.
struct VectorStroke: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case gPen
    }

    var kind: Kind
    var color: ColorRGBA
    /// Constant per-stroke alpha. Applied uniformly along the stroke's length.
    var opacity: CGFloat
    /// Radius at full pressure, in canvas pixels.
    var maxRadius: CGFloat
    /// Radius at zero pressure, in canvas pixels. Allows "press for thicker"
    /// while keeping a non-zero minimum (so feather-touch strokes still register).
    var minRadius: CGFloat
    /// Sparse stylus samples. Catmull-Rom densification happens at render time.
    var samples: [VectorStrokeSample]

    /// Canvas-space bounding box of the stroke's footprint, padded by maxRadius.
    /// Cached at construction; recomputed if samples are mutated through a
    /// dedicated method (none in V1 — strokes are immutable once committed).
    var bounds: CGRect

    init(
        kind: Kind,
        color: ColorRGBA,
        opacity: CGFloat,
        maxRadius: CGFloat,
        minRadius: CGFloat,
        samples: [VectorStrokeSample]
    ) {
        self.kind = kind
        self.color = color
        self.opacity = opacity
        self.maxRadius = maxRadius
        self.minRadius = minRadius
        self.samples = samples
        self.bounds = Self.computeBounds(samples: samples, maxRadius: maxRadius)
    }

    /// Linearly interpolate radius from pressure between `minRadius` and `maxRadius`.
    func radius(forPressure p: CGFloat) -> CGFloat {
        let pp = max(0, min(1, p))
        return minRadius + (maxRadius - minRadius) * pp
    }

    /// Returns true iff the disc at `center` with `radius` overlaps the
    /// stroke's rendered footprint. Used by the vector eraser for hit-testing
    /// during eraser drags.
    ///
    /// Approximation: the rendered ribbon is the union of disks at each
    /// densified centerline point. For hit-testing we don't densify — we
    /// check the eraser disc against each raw segment using a "minimum
    /// distance from point to segment" test, padded by the segment's
    /// per-endpoint radius. This is conservative (may report a hit slightly
    /// outside the rendered ribbon when radii vary sharply along a segment)
    /// but never reports a miss when there's a real overlap.
    func intersectsDisc(center: CGPoint, radius: CGFloat) -> Bool {
        let pad = radius + maxRadius + 1
        let inflated = bounds.insetBy(dx: -pad, dy: -pad)
        if !inflated.contains(center) { return false }
        if samples.isEmpty { return false }
        if samples.count == 1 {
            let s = samples[0]
            let strokeR = self.radius(forPressure: s.pressure)
            return hypot(center.x - s.x, center.y - s.y) <= radius + strokeR
        }
        for i in 0..<(samples.count - 1) {
            let p1 = samples[i]
            let p2 = samples[i + 1]
            let r1 = self.radius(forPressure: p1.pressure)
            let r2 = self.radius(forPressure: p2.pressure)
            let segDist = distanceFromPointToSegment(
                p: center,
                a: CGPoint(x: p1.x, y: p1.y),
                b: CGPoint(x: p2.x, y: p2.y)
            )
            if segDist <= radius + max(r1, r2) { return true }
        }
        return false
    }

    private static func computeBounds(samples: [VectorStrokeSample], maxRadius: CGFloat) -> CGRect {
        guard let first = samples.first else { return .null }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for s in samples.dropFirst() {
            if s.x < minX { minX = s.x }
            if s.x > maxX { maxX = s.x }
            if s.y < minY { minY = s.y }
            if s.y > maxY { maxY = s.y }
        }
        let pad = maxRadius + 2  // +2 px AA padding
        return CGRect(
            x: minX - pad,
            y: minY - pad,
            width: (maxX - minX) + pad * 2,
            height: (maxY - minY) + pad * 2
        )
    }
}
