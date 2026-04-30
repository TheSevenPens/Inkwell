import Foundation
import CoreGraphics

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
