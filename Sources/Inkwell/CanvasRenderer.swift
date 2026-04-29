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
    var _pad: Float = 0
}

/// Phase 2 renderer: composites the paper background plus all visible tiles per frame.
/// Lazy viewport composition per ARCHITECTURE.md decision 4 — only tiles that intersect
/// the visible viewport are drawn.
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
        float2 canvasPos = corner * u.canvasSize;
        PaperOut out;
        out.position = u.transform * float4(canvasPos, 0, 1);
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
        // Tile texture stored top-down, top row = high canvas Y.
        // corner.y = 1 (top of clip / high canvas Y) should sample uv.y = 0 (top row).
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 tile_fragment(TileOut in [[stage_in]],
                                  texture2d<float> tile [[texture(0)]],
                                  sampler smp [[sampler(0)]]) {
        return tile.sample(smp, in.uv);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let paperPipeline: any MTLRenderPipelineState
    private let tilePipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private weak var canvas: BitmapCanvas?

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
        tilePD.colorAttachments[0].isBlendingEnabled = true
        tilePD.colorAttachments[0].rgbBlendOperation = .add
        tilePD.colorAttachments[0].alphaBlendOperation = .add
        tilePD.colorAttachments[0].sourceRGBBlendFactor = .one
        tilePD.colorAttachments[0].sourceAlphaBlendFactor = .one
        tilePD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        tilePD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

    func attach(canvas: BitmapCanvas) {
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
            paperColor: BitmapCanvas.paperColor
        )
        encoder.setRenderPipelineState(paperPipeline)
        encoder.setVertexBytes(&paperUniforms, length: MemoryLayout<PaperUniforms>.size, index: 0)
        encoder.setFragmentBytes(&paperUniforms, length: MemoryLayout<PaperUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Tiles
        let visibleCoords = canvas.tilesIntersecting(visibleCanvasRect)
        encoder.setRenderPipelineState(tilePipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for coord in visibleCoords {
            guard let texture = canvas.tile(at: coord) else { continue }
            var tu = TileUniforms(
                transform: viewTransform,
                tileOrigin: SIMD2<Float>(
                    Float(coord.x * BitmapCanvas.tileSize),
                    Float(coord.y * BitmapCanvas.tileSize)
                ),
                tileSize: Float(BitmapCanvas.tileSize)
            )
            encoder.setVertexBytes(&tu, length: MemoryLayout<TileUniforms>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
