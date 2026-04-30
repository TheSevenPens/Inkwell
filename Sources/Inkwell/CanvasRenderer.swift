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

private struct AntsUniforms {
    var transform: simd_float4x4
    var canvasSize: SIMD2<Float>
    var time: Float
    var _pad: Float = 0
}

private struct VectorOverlayUniforms {
    var transform: simd_float4x4
    var color: SIMD4<Float>
    var pointSize: Float
    var _pad0: Float = 0
    var _pad1: Float = 0
    var _pad2: Float = 0
}

/// Phase 7 renderer: composites the layer tree as before, then draws the marching-ants
/// overlay if a selection is active.
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
                                  texture2d<float> mask [[texture(1)]],
                                  sampler smp [[sampler(0)]],
                                  constant TileUniforms &u [[buffer(0)]],
                                  float4 dst [[color(0)]]) {
        float4 src = tile.sample(smp, in.uv);
        float maskValue = mask.sample(smp, in.uv).r;
        src *= maskValue;
        src *= u.layerOpacity;

        float3 srcUn = src.a > 0.0001 ? src.rgb / src.a : float3(0);
        float3 dstUn = dst.a > 0.0001 ? dst.rgb / dst.a : float3(0);

        float3 blendUn;
        if (u.blendMode == 1) {
            blendUn = srcUn * dstUn;
        } else if (u.blendMode == 2) {
            blendUn = 1.0 - (1.0 - srcUn) * (1.0 - dstUn);
        } else if (u.blendMode == 3) {
            blendUn = float3(
                dstUn.r < 0.5 ? 2.0 * srcUn.r * dstUn.r : 1.0 - 2.0 * (1.0 - srcUn.r) * (1.0 - dstUn.r),
                dstUn.g < 0.5 ? 2.0 * srcUn.g * dstUn.g : 1.0 - 2.0 * (1.0 - srcUn.g) * (1.0 - dstUn.g),
                dstUn.b < 0.5 ? 2.0 * srcUn.b * dstUn.b : 1.0 - 2.0 * (1.0 - srcUn.b) * (1.0 - dstUn.b)
            );
        } else {
            blendUn = srcUn;
        }

        float3 outRgb = src.rgb * (1.0 - dst.a)
                      + dst.rgb * (1.0 - src.a)
                      + blendUn * src.a * dst.a;
        float outA = src.a + dst.a * (1.0 - src.a);
        return float4(outRgb, outA);
    }

    struct AntsUniforms {
        float4x4 transform;
        float2 canvasSize;
        float time;
    };

    struct AntsOut {
        float4 position [[position]];
        float2 selectionUV;
    };

    vertex AntsOut ants_vertex(uint vid [[vertex_id]],
                               constant AntsUniforms &u [[buffer(0)]]) {
        float2 corner = kCanvasQuadCorners[vid];
        float2 canvasPos = corner * u.canvasSize;
        AntsOut out;
        out.position = u.transform * float4(canvasPos, 0, 1);
        out.selectionUV = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 ants_fragment(AntsOut in [[stage_in]],
                                  constant AntsUniforms &u [[buffer(0)]],
                                  texture2d<float> selection [[texture(0)]],
                                  sampler smp [[sampler(0)]]) {
        float s = selection.sample(smp, in.selectionUV).r;
        // Edge thickness scales with the selection's screen-space gradient.
        float w = fwidth(s);
        if (w <= 0.0) {
            discard_fragment();
        }
        float edge = 1.0 - smoothstep(0.0, w * 1.5, abs(s - 0.5));
        if (edge < 0.05) {
            discard_fragment();
        }
        // Dashed pattern in screen space, scrolling over time.
        float p = fract((in.position.x + in.position.y - u.time * 60.0) / 8.0);
        float c = p < 0.5 ? 0.0 : 1.0;
        return float4(c, c, c, edge);
    }

    // ---- Vector path debug overlay (lines + node markers) ----

    struct VectorOverlayUniforms {
        float4x4 transform;
        float4 color;
        float pointSize;
    };

    struct VectorOverlayOut {
        float4 position [[position]];
        float pointSize [[point_size]];
    };

    vertex VectorOverlayOut vector_overlay_vertex(uint vid [[vertex_id]],
                                                   const device float2 *points [[buffer(0)]],
                                                   constant VectorOverlayUniforms &u [[buffer(1)]]) {
        VectorOverlayOut out;
        out.position = u.transform * float4(points[vid], 0, 1);
        out.pointSize = u.pointSize;
        return out;
    }

    fragment float4 vector_overlay_fragment(VectorOverlayOut in [[stage_in]],
                                             constant VectorOverlayUniforms &u [[buffer(1)]]) {
        return u.color;
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let paperPipeline: any MTLRenderPipelineState
    private let tilePipeline: any MTLRenderPipelineState
    private let antsPipeline: any MTLRenderPipelineState
    private let vectorOverlayPipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    /// Tile compositor sampler. Linear minification (smooth zoom-out, no
    /// shimmer) but **nearest magnification** (crisp pixels at zoom > 100% —
    /// matches user expectation for paint apps; bilinear here would blur the
    /// edges of vector and bitmap strokes alike when zoomed in).
    private let tileSampler: any MTLSamplerState
    private weak var canvas: Canvas?

    private let startTime = Date()

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
              let tf = library.makeFunction(name: "tile_fragment"),
              let av = library.makeFunction(name: "ants_vertex"),
              let af = library.makeFunction(name: "ants_fragment"),
              let vov = library.makeFunction(name: "vector_overlay_vertex"),
              let vof = library.makeFunction(name: "vector_overlay_fragment") else {
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
        tilePD.colorAttachments[0].isBlendingEnabled = false
        self.tilePipeline = try device.makeRenderPipelineState(descriptor: tilePD)

        // Marching ants: standard alpha-over.
        let antsPD = MTLRenderPipelineDescriptor()
        antsPD.vertexFunction = av
        antsPD.fragmentFunction = af
        antsPD.colorAttachments[0].pixelFormat = viewColorPixelFormat
        antsPD.colorAttachments[0].isBlendingEnabled = true
        antsPD.colorAttachments[0].rgbBlendOperation = .add
        antsPD.colorAttachments[0].alphaBlendOperation = .add
        antsPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        antsPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        antsPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        antsPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.antsPipeline = try device.makeRenderPipelineState(descriptor: antsPD)

        // Vector debug overlay: alpha-over so the dashed lines and node markers
        // stay legible against any background.
        let voPD = MTLRenderPipelineDescriptor()
        voPD.vertexFunction = vov
        voPD.fragmentFunction = vof
        voPD.colorAttachments[0].pixelFormat = viewColorPixelFormat
        voPD.colorAttachments[0].isBlendingEnabled = true
        voPD.colorAttachments[0].rgbBlendOperation = .add
        voPD.colorAttachments[0].alphaBlendOperation = .add
        voPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        voPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        voPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        voPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.vectorOverlayPipeline = try device.makeRenderPipelineState(descriptor: voPD)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else {
            throw RendererError.samplerFailed
        }
        self.sampler = s

        let tsd = MTLSamplerDescriptor()
        tsd.minFilter = .linear
        tsd.magFilter = .nearest
        tsd.sAddressMode = .clampToEdge
        tsd.tAddressMode = .clampToEdge
        guard let ts = device.makeSamplerState(descriptor: tsd) else {
            throw RendererError.samplerFailed
        }
        self.tileSampler = ts
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
        encoder.setFragmentSamplerState(tileSampler, index: 0)
        let defaultMask = canvas.defaultMaskTexture
        canvas.walkVisibleCompositables { layer, effectiveOpacity, blendMode in
            let visibleCoords = layer.tilesIntersecting(visibleCanvasRect)
            for coord in visibleCoords {
                guard let texture = layer.tile(at: coord) else { continue }
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
                let maskTex: any MTLTexture = layer.mask?.tile(at: coord) ?? defaultMask
                encoder.setVertexBytes(&tu, length: MemoryLayout<TileUniforms>.size, index: 0)
                encoder.setFragmentBytes(&tu, length: MemoryLayout<TileUniforms>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(maskTex, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // Marching ants overlay (only when a selection is active).
        if let selection = canvas.selection {
            var au = AntsUniforms(
                transform: viewTransform,
                canvasSize: SIMD2<Float>(Float(canvas.width), Float(canvas.height)),
                time: Float(Date().timeIntervalSince(startTime))
            )
            encoder.setRenderPipelineState(antsPipeline)
            encoder.setVertexBytes(&au, length: MemoryLayout<AntsUniforms>.size, index: 0)
            encoder.setFragmentBytes(&au, length: MemoryLayout<AntsUniforms>.size, index: 0)
            encoder.setFragmentTexture(selection.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Vector path debug overlay (View → Show Vector Path Overlay).
        if VectorOverlayController.shared.isVisible {
            drawVectorPathOverlay(encoder: encoder, canvas: canvas, viewTransform: viewTransform)
        }

        encoder.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func drawVectorPathOverlay(
        encoder: any MTLRenderCommandEncoder,
        canvas: Canvas,
        viewTransform: simd_float4x4
    ) {
        let layers = canvas.visibleVectorLayers()
        guard !layers.isEmpty else { return }
        var lineVerts: [SIMD2<Float>] = []
        var pointVerts: [SIMD2<Float>] = []
        for layer in layers {
            for stroke in layer.strokes {
                let samples = stroke.samples
                guard !samples.isEmpty else { continue }
                for (i, s) in samples.enumerated() {
                    pointVerts.append(SIMD2<Float>(Float(s.x), Float(s.y)))
                    if i < samples.count - 1 {
                        let n = samples[i + 1]
                        lineVerts.append(SIMD2<Float>(Float(s.x), Float(s.y)))
                        lineVerts.append(SIMD2<Float>(Float(n.x), Float(n.y)))
                    }
                }
            }
        }
        guard !pointVerts.isEmpty else { return }

        encoder.setRenderPipelineState(vectorOverlayPipeline)

        // Lines first (raw polyline). Cyan, ~1 px Metal default line width.
        if !lineVerts.isEmpty {
            var u = VectorOverlayUniforms(
                transform: viewTransform,
                color: SIMD4<Float>(0.20, 0.85, 1.0, 0.85),
                pointSize: 0
            )
            let lineBytes = lineVerts.count * MemoryLayout<SIMD2<Float>>.size
            guard let lineBuf = device.makeBuffer(bytes: lineVerts, length: lineBytes, options: []) else { return }
            encoder.setVertexBuffer(lineBuf, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<VectorOverlayUniforms>.size, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<VectorOverlayUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVerts.count)
        }

        // Then nodes on top. Orange, 6-px squares (Metal point sprites).
        var u = VectorOverlayUniforms(
            transform: viewTransform,
            color: SIMD4<Float>(1.0, 0.55, 0.10, 1.0),
            pointSize: 6
        )
        let pointBytes = pointVerts.count * MemoryLayout<SIMD2<Float>>.size
        guard let pointBuf = device.makeBuffer(bytes: pointVerts, length: pointBytes, options: []) else { return }
        encoder.setVertexBuffer(pointBuf, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<VectorOverlayUniforms>.size, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<VectorOverlayUniforms>.size, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointVerts.count)
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
