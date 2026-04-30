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
    var _pad: Float = 0
}

struct StampDispatch {
    var canvasCenter: CGPoint
    var radius: CGFloat
    var alpha: Float
    var angleRadians: Float
    var color: SIMD4<Float>
    var blendMode: BrushBlendMode
}

/// Phase 6 stamp pipelines:
/// - Layer painting: writes premultiplied RGBA into `.rgba8Unorm` tile textures.
///   Two flavors (normal "over" / erase "destination-out") via fixed-function blend.
/// - Mask painting: writes a single value into `.r8Unorm` mask tile textures via
///   shader-side framebuffer fetch (lerp between current mask and stamp value,
///   weighted by stamp alpha × tip alpha).
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
    };

    struct StampOut {
        float4 position [[position]];
        float2 tipUV;
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

    fragment float4 mask_stamp_fragment(StampOut in [[stage_in]],
                                        constant StampUniforms &u [[buffer(0)]],
                                        texture2d<float> tip [[texture(0)]],
                                        sampler smp [[sampler(0)]],
                                        float4 dst [[color(0)]]) {
        float tipAlpha = tip.sample(smp, in.tipUV).a;
        float a = tipAlpha * u.stampAlpha;
        float current = dst.r;
        // u.stampColor.r carries the brush's mask value (0 = hide, 1 = reveal).
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

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vfn = library.makeFunction(name: "stamp_vertex"),
              let layerFrag = library.makeFunction(name: "stamp_fragment"),
              let maskFrag = library.makeFunction(name: "mask_stamp_fragment") else {
            throw StampError.shaderFunctionMissing
        }

        // Normal layer paint (premultiplied "over").
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

        // Erase (destination-out).
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

        // Mask paint (.r8Unorm, shader-side blending via framebuffer fetch).
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

    @discardableResult
    func applyStamp(
        _ stamp: StampDispatch,
        tipTexture: any MTLTexture,
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
        guard !coords.isEmpty,
              let cb = commandQueue.makeCommandBuffer() else { return [] }
        let pipeline = (stamp.blendMode == .erase) ? erasePipeline : normalPipeline

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = layer.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            var uniforms = makeUniforms(for: stamp, tileCoord: coord)
            encoder.setRenderPipelineState(pipeline)
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

    @discardableResult
    func applyMaskStamp(
        _ stamp: StampDispatch,
        tipTexture: any MTLTexture,
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
        guard !coords.isEmpty,
              let cb = commandQueue.makeCommandBuffer() else { return [] }

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = mask.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            var uniforms = makeUniforms(for: stamp, tileCoord: coord)
            encoder.setRenderPipelineState(maskPipeline)
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

    private func makeUniforms(for stamp: StampDispatch, tileCoord: TileCoord) -> StampUniforms {
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
            stampAngleRadians: stamp.angleRadians
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
