import Foundation
import CoreGraphics
import Metal
import simd

/// Renders vector strokes as continuous swept-path ribbons.
///
/// For each segment between two adjacent polyline samples, we draw one quad
/// covering the union of the two endpoint disks (plus AA padding). The
/// fragment shader computes the signed distance from the pixel to the
/// linearly-interpolated capsule (a line segment with linearly-varying
/// radius along its length) and produces an anti-aliased coverage value.
///
/// Adjacent segments share endpoints (and identical radii at the shared
/// endpoint), so the resulting rasterization is a continuous round-jointed
/// ribbon with no per-stamp seams.
///
/// Self-overlap within a single stroke at opacity < 1 will overdarken — but
/// V1 G-Pen renders at the stroke's constant opacity (typically 1.0), so this
/// is a non-issue today. Soft-edged vector brushes (deferred) will need a
/// two-pass scratch-buffer approach.
final class StrokeRibbonRenderer {
    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float2 kRibbonQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    struct SegmentUniforms {
        float2 quadOriginTile;   // tile-local pixel coords of quad's lower-left corner
        float2 quadSizeTile;     // tile-local pixel size of the quad
        float2 tileSizePixels;
        float2 tileOriginCanvas; // canvas-space origin of the tile
        float2 p0;               // canvas-space segment start
        float2 p1;               // canvas-space segment end
        float r0;                // radius at p0 (canvas pixels)
        float r1;                // radius at p1 (canvas pixels)
        float4 color;            // sRGB straight RGBA; alpha is the per-stroke opacity
    };

    struct SegmentOut {
        float4 position [[position]];
        float2 canvasPos;
    };

    vertex SegmentOut ribbon_vertex(uint vid [[vertex_id]],
                                    constant SegmentUniforms &u [[buffer(0)]]) {
        float2 corner = kRibbonQuadCorners[vid];
        float2 tilePos = u.quadOriginTile + corner * u.quadSizeTile;
        float2 ndc = (tilePos / u.tileSizePixels) * 2.0 - 1.0;
        SegmentOut out;
        out.position = float4(ndc, 0, 1);
        out.canvasPos = u.tileOriginCanvas + tilePos;
        return out;
    }

    fragment float4 ribbon_fragment(SegmentOut in [[stage_in]],
                                    constant SegmentUniforms &u [[buffer(0)]]) {
        float2 d = u.p1 - u.p0;
        float lenSq = dot(d, d);
        float2 toPixel = in.canvasPos - u.p0;
        // Degenerate segment (single sample): treat as a disk at p0 with radius r0.
        float t;
        if (lenSq < 1e-6) {
            t = 0.0;
        } else {
            t = saturate(dot(toPixel, d) / lenSq);
        }
        float2 closest = u.p0 + t * d;
        float radius = mix(u.r0, u.r1, t);
        float dist = length(in.canvasPos - closest) - radius;
        float coverage = saturate(0.5 - dist);
        if (coverage <= 0.0) {
            discard_fragment();
        }
        float a = coverage * u.color.a;
        // Premultiplied output for "over" blend.
        return float4(u.color.rgb * a, a);
    }
    """

    private struct SegmentUniformsCPU {
        var quadOriginTile: SIMD2<Float>
        var quadSizeTile: SIMD2<Float>
        var tileSizePixels: SIMD2<Float>
        var tileOriginCanvas: SIMD2<Float>
        var p0: SIMD2<Float>
        var p1: SIMD2<Float>
        var r0: Float
        var r1: Float
        var _pad0: Float = 0
        var _pad1: Float = 0
        var color: SIMD4<Float>
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vfn = library.makeFunction(name: "ribbon_vertex"),
              let ffn = library.makeFunction(name: "ribbon_fragment") else {
            throw RibbonError.shaderFunctionMissing
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one  // premultiplied source
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: pd)
    }

    /// Densify the stroke's polyline into a list of (point, radius) pairs along
    /// a Catmull-Rom curve through the samples. The first sample contributes a
    /// disk at its position; each subsequent original-sample interval is
    /// subdivided into `n` sub-segments.
    static func densify(_ stroke: VectorStroke) -> [(point: CGPoint, radius: CGFloat)] {
        let samples = stroke.samples
        guard !samples.isEmpty else { return [] }
        if samples.count == 1 {
            let s = samples[0]
            return [(s.point, stroke.radius(forPressure: s.pressure))]
        }
        var out: [(CGPoint, CGFloat)] = []
        out.append((samples[0].point, stroke.radius(forPressure: samples[0].pressure)))
        for i in 0..<(samples.count - 1) {
            let p1 = samples[i]
            let p2 = samples[i + 1]
            let p0 = i > 0 ? samples[i - 1] : p1
            let p3 = (i + 2) < samples.count ? samples[i + 2] : p2
            let chord = hypot(p2.x - p1.x, p2.y - p1.y)
            // 1 sub-step every ~2 px of chord; clamp to [4, 64].
            let n = max(4, min(64, Int(chord / 2.0)))
            for step in 1...n {
                let t = CGFloat(step) / CGFloat(n)
                let pt = catmullRom(
                    CGPoint(x: p0.x, y: p0.y),
                    CGPoint(x: p1.x, y: p1.y),
                    CGPoint(x: p2.x, y: p2.y),
                    CGPoint(x: p3.x, y: p3.y),
                    t: t
                )
                let pressure = p1.pressure + (p2.pressure - p1.pressure) * t
                let r = stroke.radius(forPressure: pressure)
                out.append((pt, r))
            }
        }
        return out
    }

    /// Render `stroke` into the given vector layer's tiles. Tiles that overlap
    /// the stroke's bounding box are ensured (allocated if needed) and the
    /// stroke is drawn into each one in a single render pass per tile.
    ///
    /// Returns the set of tile coords the stroke wrote to.
    @discardableResult
    func renderStroke(
        _ stroke: VectorStroke,
        into layer: VectorLayer
    ) -> Set<TileCoord> {
        let coords = layer.tilesIntersecting(stroke.bounds)
        var written: Set<TileCoord> = []
        for coord in coords {
            if renderStrokeIntoTile(stroke, layer: layer, coord: coord) {
                written.insert(coord)
            }
        }
        return written
    }

    /// Render `stroke` into one specific tile of `layer`. Returns true iff at
    /// least one segment actually drew into the tile.
    @discardableResult
    func renderStrokeIntoTile(
        _ stroke: VectorStroke,
        layer: VectorLayer,
        coord: TileCoord
    ) -> Bool {
        let densified = Self.densify(stroke)
        guard !densified.isEmpty else { return false }
        let tileRect = layer.canvasRect(for: coord)
        guard let cb = commandQueue.makeCommandBuffer() else { return false }
        let tile = layer.ensureTile(at: coord)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tile
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        encoder.setRenderPipelineState(pipeline)

        let tileOrigin = SIMD2<Float>(
            Float(coord.x * Canvas.tileSize),
            Float(coord.y * Canvas.tileSize)
        )
        let tileSize = SIMD2<Float>(Float(Canvas.tileSize), Float(Canvas.tileSize))
        let strokeColor = SIMD4<Float>(
            Float(stroke.color.r),
            Float(stroke.color.g),
            Float(stroke.color.b),
            Float(stroke.opacity * stroke.color.a)
        )
        var didDraw = false

        if densified.count == 1 {
            let (a, ra) = densified[0]
            didDraw = drawSegment(
                encoder: encoder,
                a: a, b: a, ra: ra, rb: ra,
                tileRect: tileRect,
                tileOrigin: tileOrigin,
                tileSize: tileSize,
                color: strokeColor
            ) || didDraw
        } else {
            for i in 0..<(densified.count - 1) {
                let (a, ra) = densified[i]
                let (b, rb) = densified[i + 1]
                didDraw = drawSegment(
                    encoder: encoder,
                    a: a, b: b, ra: ra, rb: rb,
                    tileRect: tileRect,
                    tileOrigin: tileOrigin,
                    tileSize: tileSize,
                    color: strokeColor
                ) || didDraw
            }
        }

        encoder.endEncoding()
        cb.commit()
        return didDraw
    }

    /// Draw a single capsule segment from (a, ra) to (b, rb) directly into the
    /// layer's overlapping tiles. Used for in-flight live preview where each
    /// stylus sample produces one new dense polyline segment.
    @discardableResult
    func drawCapsule(
        from a: CGPoint, radiusA ra: CGFloat,
        to b: CGPoint, radiusB rb: CGFloat,
        color: ColorRGBA, opacity: CGFloat,
        into layer: VectorLayer
    ) -> Set<TileCoord> {
        let segMinX = min(a.x - ra, b.x - rb) - 1
        let segMaxX = max(a.x + ra, b.x + rb) + 1
        let segMinY = min(a.y - ra, b.y - rb) - 1
        let segMaxY = max(a.y + ra, b.y + rb) + 1
        let bbox = CGRect(
            x: segMinX, y: segMinY,
            width: segMaxX - segMinX, height: segMaxY - segMinY
        )
        let coords = layer.tilesIntersecting(bbox)
        guard !coords.isEmpty else { return [] }

        let strokeColor = SIMD4<Float>(
            Float(color.r),
            Float(color.g),
            Float(color.b),
            Float(opacity * color.a)
        )
        let tileSize = SIMD2<Float>(Float(Canvas.tileSize), Float(Canvas.tileSize))

        guard let cb = commandQueue.makeCommandBuffer() else { return [] }
        var written: Set<TileCoord> = []
        for coord in coords {
            let tile = layer.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            encoder.setRenderPipelineState(pipeline)
            let tileRect = layer.canvasRect(for: coord)
            let tileOrigin = SIMD2<Float>(
                Float(coord.x * Canvas.tileSize),
                Float(coord.y * Canvas.tileSize)
            )
            let drew = drawSegment(
                encoder: encoder,
                a: a, b: b, ra: ra, rb: rb,
                tileRect: tileRect,
                tileOrigin: tileOrigin,
                tileSize: tileSize,
                color: strokeColor
            )
            encoder.endEncoding()
            if drew { written.insert(coord) }
        }
        cb.commit()
        return written
    }

    private func drawSegment(
        encoder: any MTLRenderCommandEncoder,
        a: CGPoint, b: CGPoint, ra: CGFloat, rb: CGFloat,
        tileRect: CGRect,
        tileOrigin: SIMD2<Float>,
        tileSize: SIMD2<Float>,
        color: SIMD4<Float>
    ) -> Bool {
        let segMinX = min(a.x - ra, b.x - rb) - 1
        let segMaxX = max(a.x + ra, b.x + rb) + 1
        let segMinY = min(a.y - ra, b.y - rb) - 1
        let segMaxY = max(a.y + ra, b.y + rb) + 1
        let segRect = CGRect(
            x: segMinX, y: segMinY,
            width: segMaxX - segMinX, height: segMaxY - segMinY
        )
        let clipped = segRect.intersection(tileRect)
        if clipped.isNull || clipped.width < 0.5 || clipped.height < 0.5 { return false }
        var u = SegmentUniformsCPU(
            quadOriginTile: SIMD2<Float>(
                Float(clipped.minX - tileRect.minX),
                Float(clipped.minY - tileRect.minY)
            ),
            quadSizeTile: SIMD2<Float>(Float(clipped.width), Float(clipped.height)),
            tileSizePixels: tileSize,
            tileOriginCanvas: tileOrigin,
            p0: SIMD2<Float>(Float(a.x), Float(a.y)),
            p1: SIMD2<Float>(Float(b.x), Float(b.y)),
            r0: Float(ra),
            r1: Float(rb),
            color: color
        )
        encoder.setVertexBytes(&u, length: MemoryLayout<SegmentUniformsCPU>.size, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<SegmentUniformsCPU>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        return true
    }

    enum RibbonError: Error, LocalizedError {
        case shaderFunctionMissing
        var errorDescription: String? {
            switch self {
            case .shaderFunctionMissing: "Could not load ribbon shader functions."
            }
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
