import Foundation
import Metal
import simd

private struct StampUniforms {
    var stampCenterTilePixels: SIMD2<Float>
    var stampRadiusPixels: Float
    var stampAlpha: Float
    var stampColor: SIMD4<Float>
    var tileSizePixels: SIMD2<Float>
}

/// Phase 2 stamp pipeline: one render pass per (stamp × affected tile).
/// The fragment shader samples the tip mask, modulates by brush color and stamp alpha,
/// and outputs premultiplied RGBA. Metal blend state composes "over" into the tile texture.
///
/// PLAN.md Phase 2 calls for "Stamp rasterizer writes into tile textures via Metal compute
/// shader." We use render-to-texture instead of a compute kernel because Metal's blend state
/// gives us correct premultiplied-over compositing for free; a compute kernel would need to
/// implement the blend manually. The behavior is identical and the dispatch cost is comparable
/// at our stamp counts.
final class StampRenderer {
    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float2 kStampQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    struct StampUniforms {
        float2 stampCenterTilePixels;
        float stampRadiusPixels;
        float stampAlpha;
        float4 stampColor;
        float2 tileSizePixels;
    };

    struct StampOut {
        float4 position [[position]];
        float2 tipUV;
    };

    vertex StampOut stamp_vertex(uint vid [[vertex_id]],
                                 constant StampUniforms &u [[buffer(0)]]) {
        float2 corner = kStampQuadCorners[vid];
        float diameter = u.stampRadiusPixels * 2.0;
        float2 tilePos = u.stampCenterTilePixels + (corner - 0.5) * diameter;
        // Map tile-local pixel coords (canvas Y-up) to NDC.
        // Render-to-texture: NDC y = +1 lands at the top of stored texture data,
        // which matches our convention of top-row-of-data == high canvas Y.
        float2 ndc = (tilePos / u.tileSizePixels) * 2.0 - 1.0;
        StampOut out;
        out.position = float4(ndc, 0, 1);
        out.tipUV = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 stamp_fragment(StampOut in [[stage_in]],
                                   constant StampUniforms &u [[buffer(0)]],
                                   texture2d<float> tip [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
        float tipAlpha = tip.sample(smp, in.tipUV).a;
        float a = tipAlpha * u.stampAlpha;
        return float4(u.stampColor.rgb * a, a);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vfn = library.makeFunction(name: "stamp_vertex"),
              let ffn = library.makeFunction(name: "stamp_fragment") else {
            throw StampError.shaderFunctionMissing
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToZero
        sd.tAddressMode = .clampToZero
        guard let s = device.makeSamplerState(descriptor: sd) else {
            throw StampError.samplerFailed
        }
        self.sampler = s
    }

    /// Apply a single stamp at the given canvas position. Returns the set of tiles affected.
    /// Caller is responsible for snapshotting the BEFORE state of any newly-affected tiles
    /// before invoking this method.
    @discardableResult
    func applyStamp(
        at canvasCenter: CGPoint,
        tipTexture: any MTLTexture,
        radiusInCanvasPixels: CGFloat,
        color: SIMD4<Float>,
        alpha: Float,
        canvas: BitmapCanvas
    ) -> Set<TileCoord> {
        let r = radiusInCanvasPixels
        let bbox = CGRect(
            x: canvasCenter.x - r,
            y: canvasCenter.y - r,
            width: r * 2,
            height: r * 2
        )
        let coords = canvas.tilesIntersecting(bbox)
        guard !coords.isEmpty,
              let cb = commandQueue.makeCommandBuffer() else { return [] }

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = canvas.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }

            let cxLocal = Float(canvasCenter.x - CGFloat(coord.x * BitmapCanvas.tileSize))
            let cyLocal = Float(canvasCenter.y - CGFloat(coord.y * BitmapCanvas.tileSize))
            var uniforms = StampUniforms(
                stampCenterTilePixels: SIMD2<Float>(cxLocal, cyLocal),
                stampRadiusPixels: Float(r),
                stampAlpha: alpha,
                stampColor: color,
                tileSizePixels: SIMD2<Float>(Float(BitmapCanvas.tileSize), Float(BitmapCanvas.tileSize))
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentTexture(tipTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            dirty.insert(coord)
        }
        cb.commit()
        return dirty
    }

    enum StampError: Error, LocalizedError {
        case shaderFunctionMissing, samplerFailed

        var errorDescription: String? {
            switch self {
            case .shaderFunctionMissing: "Could not load stamp shader functions."
            case .samplerFailed: "Could not create stamp sampler."
            }
        }
    }
}
