import Foundation
import Metal
import simd

private struct StampUniforms {
    var stampCenterTilePixels: SIMD2<Float>
    var stampRadiusPixels: Float
    var stampAlpha: Float
    var stampColor: SIMD4<Float>
    var tileSizePixels: SIMD2<Float>
    var stampAngleRadians: Float
    var _pad0: Float = 0
    var tileOriginCanvas: SIMD2<Float>
    var canvasSize: SIMD2<Float>
}

struct StampDispatch {
    var canvasCenter: CGPoint
    var radius: CGFloat
    var alpha: Float
    var angleRadians: Float
    var color: SIMD4<Float>
    var blendMode: BrushBlendMode
}

/// Phase 7 stamp pipelines:
/// - Layer painting (.rgba8Unorm, normal "over" / erase "destination-out")
/// - Mask painting (.r8Unorm, shader-side blending via framebuffer fetch)
///
/// All three pipelines now sample the document-level selection mask at the current
/// canvas pixel and multiply stamp output by the selection value, per
/// ARCHITECTURE.md decision 12. When no selection is active, the caller binds a
/// 1×1 white texture (full constraint = 1.0) so the math is a no-op.
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
        float stampAngleRadians;
        float2 tileOriginCanvas;
        float2 canvasSize;
    };

    struct StampOut {
        float4 position [[position]];
        float2 tipUV;
        float2 selectionUV;
    };

    vertex StampOut stamp_vertex(uint vid [[vertex_id]],
                                 constant StampUniforms &u [[buffer(0)]]) {
        float2 corner = kStampQuadCorners[vid];
        float diameter = u.stampRadiusPixels * 2.0;
        float2 offset = (corner - 0.5) * diameter;
        float c = cos(u.stampAngleRadians);
        float s = sin(u.stampAngleRadians);
        float2 rotated = float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
        float2 tilePos = u.stampCenterTilePixels + rotated;
        float2 ndc = (tilePos / u.tileSizePixels) * 2.0 - 1.0;
        float2 canvasPos = u.tileOriginCanvas + tilePos;
        // Selection texture is stored top-down (top row = high canvas Y); flip Y.
        float2 selUV = float2(canvasPos.x / u.canvasSize.x,
                              1.0 - canvasPos.y / u.canvasSize.y);
        StampOut out;
        out.position = float4(ndc, 0, 1);
        out.tipUV = float2(corner.x, 1.0 - corner.y);
        out.selectionUV = selUV;
        return out;
    }

    fragment float4 stamp_fragment(StampOut in [[stage_in]],
                                   constant StampUniforms &u [[buffer(0)]],
                                   texture2d<float> tip [[texture(0)]],
                                   texture2d<float> selection [[texture(1)]],
                                   sampler smp [[sampler(0)]]) {
        float tipAlpha = tip.sample(smp, in.tipUV).a;
        float selSample = selection.sample(smp, in.selectionUV).r;
        float a = tipAlpha * u.stampAlpha * selSample;
        return float4(u.stampColor.rgb * a, a);
    }

    fragment float4 mask_stamp_fragment(StampOut in [[stage_in]],
                                        constant StampUniforms &u [[buffer(0)]],
                                        texture2d<float> tip [[texture(0)]],
                                        texture2d<float> selection [[texture(1)]],
                                        sampler smp [[sampler(0)]],
                                        float4 dst [[color(0)]]) {
        float tipAlpha = tip.sample(smp, in.tipUV).a;
        float selSample = selection.sample(smp, in.selectionUV).r;
        float a = tipAlpha * u.stampAlpha * selSample;
        float current = dst.r;
        float target = u.stampColor.r;
        float newValue = target * a + current * (1.0 - a);
        return float4(newValue, 0.0, 0.0, 1.0);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let normalPipeline: any MTLRenderPipelineState
    private let erasePipeline: any MTLRenderPipelineState
    private let maskPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    /// Active batch buffer. While non-nil, applyStamp / applyMaskStamp encode
    /// into this buffer instead of allocating a new one per call. Caller pairs
    /// `beginBatch()` and `commitBatch()` around a sequence of stamp dispatches.
    private var currentBatch: (any MTLCommandBuffer)?

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vfn = library.makeFunction(name: "stamp_vertex"),
              let layerFrag = library.makeFunction(name: "stamp_fragment"),
              let maskFrag = library.makeFunction(name: "mask_stamp_fragment") else {
            throw StampError.shaderFunctionMissing
        }

        let normalPD = MTLRenderPipelineDescriptor()
        normalPD.vertexFunction = vfn
        normalPD.fragmentFunction = layerFrag
        normalPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        normalPD.colorAttachments[0].isBlendingEnabled = true
        normalPD.colorAttachments[0].rgbBlendOperation = .add
        normalPD.colorAttachments[0].alphaBlendOperation = .add
        normalPD.colorAttachments[0].sourceRGBBlendFactor = .one
        normalPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        normalPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        normalPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.normalPipeline = try device.makeRenderPipelineState(descriptor: normalPD)

        let erasePD = MTLRenderPipelineDescriptor()
        erasePD.vertexFunction = vfn
        erasePD.fragmentFunction = layerFrag
        erasePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        erasePD.colorAttachments[0].isBlendingEnabled = true
        erasePD.colorAttachments[0].rgbBlendOperation = .add
        erasePD.colorAttachments[0].alphaBlendOperation = .add
        erasePD.colorAttachments[0].sourceRGBBlendFactor = .zero
        erasePD.colorAttachments[0].sourceAlphaBlendFactor = .zero
        erasePD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        erasePD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.erasePipeline = try device.makeRenderPipelineState(descriptor: erasePD)

        let maskPD = MTLRenderPipelineDescriptor()
        maskPD.vertexFunction = vfn
        maskPD.fragmentFunction = maskFrag
        maskPD.colorAttachments[0].pixelFormat = .r8Unorm
        maskPD.colorAttachments[0].isBlendingEnabled = false
        self.maskPipeline = try device.makeRenderPipelineState(descriptor: maskPD)

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

    /// Begin a stamp batch. While a batch is active, every applyStamp /
    /// applyMaskStamp call encodes into a single shared MTLCommandBuffer
    /// instead of allocating and committing one per stamp. This is critical at
    /// high tablet rates (300+ Hz) where per-stamp commits would otherwise
    /// flood the GPU command queue and stall presentation.
    func beginBatch() {
        guard currentBatch == nil else { return }
        currentBatch = commandQueue.makeCommandBuffer()
    }

    /// Commit the active batch (if any). Safe to call when no batch is active.
    func commitBatch() {
        currentBatch?.commit()
        currentBatch = nil
    }

    @discardableResult
    func applyStamp(
        _ stamp: StampDispatch,
        tipTexture: any MTLTexture,
        selectionTexture: any MTLTexture,
        layer: BitmapLayer
    ) -> Set<TileCoord> {
        let r = stamp.radius
        let halfBox = r * 1.42
        let bbox = CGRect(
            x: stamp.canvasCenter.x - halfBox,
            y: stamp.canvasCenter.y - halfBox,
            width: halfBox * 2,
            height: halfBox * 2
        )
        let coords = layer.tilesIntersecting(bbox)
        guard !coords.isEmpty else { return [] }
        let batched = currentBatch != nil
        guard let cb = currentBatch ?? commandQueue.makeCommandBuffer() else { return [] }
        let pipeline = (stamp.blendMode == .erase) ? erasePipeline : normalPipeline

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = layer.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            var uniforms = makeUniforms(
                for: stamp,
                tileCoord: coord,
                canvasWidth: layer.canvasWidth,
                canvasHeight: layer.canvasHeight
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentTexture(tipTexture, index: 0)
            encoder.setFragmentTexture(selectionTexture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            dirty.insert(coord)
        }
        if !batched { cb.commit() }
        return dirty
    }

    @discardableResult
    func applyMaskStamp(
        _ stamp: StampDispatch,
        tipTexture: any MTLTexture,
        selectionTexture: any MTLTexture,
        mask: LayerMask
    ) -> Set<TileCoord> {
        let r = stamp.radius
        let halfBox = r * 1.42
        let bbox = CGRect(
            x: stamp.canvasCenter.x - halfBox,
            y: stamp.canvasCenter.y - halfBox,
            width: halfBox * 2,
            height: halfBox * 2
        )
        let coords = mask.tilesIntersecting(bbox)
        guard !coords.isEmpty else { return [] }
        let batched = currentBatch != nil
        guard let cb = currentBatch ?? commandQueue.makeCommandBuffer() else { return [] }

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = mask.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            var uniforms = makeUniforms(
                for: stamp,
                tileCoord: coord,
                canvasWidth: mask.canvasWidth,
                canvasHeight: mask.canvasHeight
            )
            encoder.setRenderPipelineState(maskPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StampUniforms>.size, index: 0)
            encoder.setFragmentTexture(tipTexture, index: 0)
            encoder.setFragmentTexture(selectionTexture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            dirty.insert(coord)
        }
        if !batched { cb.commit() }
        return dirty
    }

    private func makeUniforms(
        for stamp: StampDispatch,
        tileCoord: TileCoord,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> StampUniforms {
        let cxLocal = Float(stamp.canvasCenter.x - CGFloat(tileCoord.x * Canvas.tileSize))
        let cyLocal = Float(stamp.canvasCenter.y - CGFloat(tileCoord.y * Canvas.tileSize))
        return StampUniforms(
            stampCenterTilePixels: SIMD2<Float>(cxLocal, cyLocal),
            stampRadiusPixels: Float(stamp.radius),
            stampAlpha: stamp.alpha,
            stampColor: stamp.color,
            tileSizePixels: SIMD2<Float>(
                Float(Canvas.tileSize),
                Float(Canvas.tileSize)
            ),
            stampAngleRadians: stamp.angleRadians,
            tileOriginCanvas: SIMD2<Float>(
                Float(tileCoord.x * Canvas.tileSize),
                Float(tileCoord.y * Canvas.tileSize)
            ),
            canvasSize: SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
        )
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
