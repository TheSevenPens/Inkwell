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

/// Phase 3 stamp pipeline: per-stamp render-to-texture into affected tiles.
/// Two pipeline states — normal (premultiplied over) and erase (destination-out) —
/// share the same shader; the blend state differs.
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
        // Premultiplied output. For erase, the GPU's destination-out blend uses the alpha
        // and ignores the rgb anyway, so this single shader serves both modes.
        return float4(u.stampColor.rgb * a, a);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let normalPipeline: any MTLRenderPipelineState
    private let erasePipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState

    init(device: any MTLDevice, commandQueue: any MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vfn = library.makeFunction(name: "stamp_vertex"),
              let ffn = library.makeFunction(name: "stamp_fragment") else {
            throw StampError.shaderFunctionMissing
        }

        // Normal: premultiplied "over"
        let normalPD = MTLRenderPipelineDescriptor()
        normalPD.vertexFunction = vfn
        normalPD.fragmentFunction = ffn
        normalPD.colorAttachments[0].pixelFormat = .rgba8Unorm
        normalPD.colorAttachments[0].isBlendingEnabled = true
        normalPD.colorAttachments[0].rgbBlendOperation = .add
        normalPD.colorAttachments[0].alphaBlendOperation = .add
        normalPD.colorAttachments[0].sourceRGBBlendFactor = .one
        normalPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        normalPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        normalPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.normalPipeline = try device.makeRenderPipelineState(descriptor: normalPD)

        // Erase: destination-out (dst * (1 - srcA))
        let erasePD = MTLRenderPipelineDescriptor()
        erasePD.vertexFunction = vfn
        erasePD.fragmentFunction = ffn
        erasePD.colorAttachments[0].pixelFormat = .rgba8Unorm
        erasePD.colorAttachments[0].isBlendingEnabled = true
        erasePD.colorAttachments[0].rgbBlendOperation = .add
        erasePD.colorAttachments[0].alphaBlendOperation = .add
        erasePD.colorAttachments[0].sourceRGBBlendFactor = .zero
        erasePD.colorAttachments[0].sourceAlphaBlendFactor = .zero
        erasePD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        erasePD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.erasePipeline = try device.makeRenderPipelineState(descriptor: erasePD)

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
        canvas: BitmapCanvas
    ) -> Set<TileCoord> {
        let r = stamp.radius
        // Rotated-tip bounding box: round tips don't change, but reserve sqrt(2) for
        // future asymmetric tips to stay safe under rotation.
        let halfBox = r * 1.42
        let bbox = CGRect(
            x: stamp.canvasCenter.x - halfBox,
            y: stamp.canvasCenter.y - halfBox,
            width: halfBox * 2,
            height: halfBox * 2
        )
        let coords = canvas.tilesIntersecting(bbox)
        guard !coords.isEmpty,
              let cb = commandQueue.makeCommandBuffer() else { return [] }
        let pipeline = (stamp.blendMode == .erase) ? erasePipeline : normalPipeline

        var dirty: Set<TileCoord> = []
        for coord in coords {
            let tile = canvas.ensureTile(at: coord)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tile
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }

            let cxLocal = Float(stamp.canvasCenter.x - CGFloat(coord.x * BitmapCanvas.tileSize))
            let cyLocal = Float(stamp.canvasCenter.y - CGFloat(coord.y * BitmapCanvas.tileSize))
            var uniforms = StampUniforms(
                stampCenterTilePixels: SIMD2<Float>(cxLocal, cyLocal),
                stampRadiusPixels: Float(r),
                stampAlpha: stamp.alpha,
                stampColor: stamp.color,
                tileSizePixels: SIMD2<Float>(
                    Float(BitmapCanvas.tileSize),
                    Float(BitmapCanvas.tileSize)
                ),
                stampAngleRadians: stamp.angleRadians
            )
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
