import Foundation
import Metal
import MetalKit
import simd

private struct PaperUniforms {
    var transform: simd_float4x4
    var canvasSize: SIMD2<Float>
    var _pad0: Float = 0
    var _pad1: Float = 0
    var paperColor: SIMD4<Float>
}

private struct TileUniforms {
    var transform: simd_float4x4
    var tileOrigin: SIMD2<Float>
    var tileSize: Float
    var layerOpacity: Float
    var blendMode: Int32
    var _pad: Int32 = 0
}

/// Phase 4 renderer: walks the layer tree, composites visible tiles per layer
/// using framebuffer fetch for blend-mode math. Pass-through groups: group
/// opacity multiplies down through children; group blend mode is not isolated.
final class CanvasRenderer {
    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float2 kCanvasQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    struct PaperUniforms {
        float4x4 transform;
        float2 canvasSize;
        float4 paperColor;
    };

    struct PaperOut {
        float4 position [[position]];
    };

    vertex PaperOut paper_vertex(uint vid [[vertex_id]],
                                 constant PaperUniforms &u [[buffer(0)]]) {
        float2 corner = kCanvasQuadCorners[vid];
        PaperOut out;
        out.position = u.transform * float4(corner * u.canvasSize, 0, 1);
        return out;
    }

    fragment float4 paper_fragment(PaperOut in [[stage_in]],
                                   constant PaperUniforms &u [[buffer(0)]]) {
        return u.paperColor;
    }

    struct TileUniforms {
        float4x4 transform;
        float2 tileOrigin;
        float tileSize;
        float layerOpacity;
        int blendMode;
    };

    struct TileOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex TileOut tile_vertex(uint vid [[vertex_id]],
                               constant TileUniforms &u [[buffer(0)]]) {
        float2 corner = kCanvasQuadCorners[vid];
        float2 canvasPos = u.tileOrigin + corner * u.tileSize;
        TileOut out;
        out.position = u.transform * float4(canvasPos, 0, 1);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 tile_fragment(TileOut in [[stage_in]],
                                  texture2d<float> tile [[texture(0)]],
                                  sampler smp [[sampler(0)]],
                                  constant TileUniforms &u [[buffer(0)]],
                                  float4 dst [[color(0)]]) {
        // Premultiplied source, attenuated by the layer's effective opacity.
        float4 src = tile.sample(smp, in.uv) * u.layerOpacity;

        // Un-premultiply for blend-mode math.
        float3 srcUn = src.a > 0.0001 ? src.rgb / src.a : float3(0);
        float3 dstUn = dst.a > 0.0001 ? dst.rgb / dst.a : float3(0);

        float3 blendUn;
        if (u.blendMode == 1) {
            // Multiply
            blendUn = srcUn * dstUn;
        } else if (u.blendMode == 2) {
            // Screen
            blendUn = 1.0 - (1.0 - srcUn) * (1.0 - dstUn);
        } else if (u.blendMode == 3) {
            // Overlay
            blendUn = float3(
                dstUn.r < 0.5 ? 2.0 * srcUn.r * dstUn.r : 1.0 - 2.0 * (1.0 - srcUn.r) * (1.0 - dstUn.r),
                dstUn.g < 0.5 ? 2.0 * srcUn.g * dstUn.g : 1.0 - 2.0 * (1.0 - srcUn.g) * (1.0 - dstUn.g),
                dstUn.b < 0.5 ? 2.0 * srcUn.b * dstUn.b : 1.0 - 2.0 * (1.0 - srcUn.b) * (1.0 - dstUn.b)
            );
        } else {
            // Normal
            blendUn = srcUn;
        }

        // Non-isolated Porter-Duff "over" with blend applied to the overlap region.
        // Inputs and outputs are premultiplied alpha.
        float3 outRgb = src.rgb * (1.0 - dst.a)
                      + dst.rgb * (1.0 - src.a)
                      + blendUn * src.a * dst.a;
        float outA = src.a + dst.a * (1.0 - src.a);
        return float4(outRgb, outA);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let paperPipeline: any MTLRenderPipelineState
    private let tilePipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private weak var canvas: Canvas?

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        viewColorPixelFormat: MTLPixelFormat
    ) throws {
        self.device = device
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let pv = library.makeFunction(name: "paper_vertex"),
              let pf = library.makeFunction(name: "paper_fragment"),
              let tv = library.makeFunction(name: "tile_vertex"),
              let tf = library.makeFunction(name: "tile_fragment") else {
            throw RendererError.shaderFunctionMissing
        }

        let paperPD = MTLRenderPipelineDescriptor()
        paperPD.vertexFunction = pv
        paperPD.fragmentFunction = pf
        paperPD.colorAttachments[0].pixelFormat = viewColorPixelFormat
        self.paperPipeline = try device.makeRenderPipelineState(descriptor: paperPD)

        let tilePD = MTLRenderPipelineDescriptor()
        tilePD.vertexFunction = tv
        tilePD.fragmentFunction = tf
        tilePD.colorAttachments[0].pixelFormat = viewColorPixelFormat
        // Shader does its own blending via framebuffer fetch; disable fixed-function blend.
        tilePD.colorAttachments[0].isBlendingEnabled = false
        self.tilePipeline = try device.makeRenderPipelineState(descriptor: tilePD)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else {
            throw RendererError.samplerFailed
        }
        self.sampler = s
    }

    func attach(canvas: Canvas) {
        self.canvas = canvas
    }

    func render(
        in view: MTKView,
        viewTransform: simd_float4x4,
        visibleCanvasRect: CGRect
    ) {
        guard let canvas,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer() else { return }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Paper background
        var paperUniforms = PaperUniforms(
            transform: viewTransform,
            canvasSize: SIMD2<Float>(Float(canvas.width), Float(canvas.height)),
            paperColor: Canvas.paperColor
        )
        encoder.setRenderPipelineState(paperPipeline)
        encoder.setVertexBytes(&paperUniforms, length: MemoryLayout<PaperUniforms>.size, index: 0)
        encoder.setFragmentBytes(&paperUniforms, length: MemoryLayout<PaperUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Layer tree compositing
        encoder.setRenderPipelineState(tilePipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        canvas.walkVisibleBitmapLayers { bitmap, effectiveOpacity, blendMode in
            let visibleCoords = bitmap.tilesIntersecting(visibleCanvasRect)
            for coord in visibleCoords {
                guard let texture = bitmap.tile(at: coord) else { continue }
                var tu = TileUniforms(
                    transform: viewTransform,
                    tileOrigin: SIMD2<Float>(
                        Float(coord.x * Canvas.tileSize),
                        Float(coord.y * Canvas.tileSize)
                    ),
                    tileSize: Float(Canvas.tileSize),
                    layerOpacity: Float(effectiveOpacity),
                    blendMode: blendMode.shaderIndex
                )
                encoder.setVertexBytes(&tu, length: MemoryLayout<TileUniforms>.size, index: 0)
                encoder.setFragmentBytes(&tu, length: MemoryLayout<TileUniforms>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    enum RendererError: Error, LocalizedError {
        case shaderFunctionMissing, samplerFailed

        var errorDescription: String? {
            switch self {
            case .shaderFunctionMissing: "Could not load shader functions."
            case .samplerFailed: "Could not create sampler state."
            }
        }
    }
}
