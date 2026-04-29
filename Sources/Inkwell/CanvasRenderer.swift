import Foundation
import Metal
import MetalKit
import simd

private struct CanvasUniforms {
    var transform: simd_float4x4
}

/// Phase 1 renderer: uploads the BitmapCanvas pixels to a single MTLTexture and draws
/// it as a textured quad per frame, with the current view transform.
/// Phase 2 will replace whole-texture upload with per-tile upload.
final class CanvasRenderer {
    private static let metalSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct CanvasUniforms {
        float4x4 transform;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 kQuadCorners[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    vertex VertexOut canvas_vertex(uint vid [[vertex_id]],
                                   constant CanvasUniforms &uniforms [[buffer(0)]]) {
        float2 corner = kQuadCorners[vid];
        VertexOut out;
        out.position = uniforms.transform * float4(corner, 0.0, 1.0);
        // CGContext stores top-of-image at the END of the byte buffer; texture origin is
        // top-left of stored bytes. Flip uv.y so canvas-top displays at clip-top.
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    fragment float4 canvas_fragment(VertexOut in [[stage_in]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
        return canvas.sample(smp, in.uv);
    }
    """

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private var canvasTexture: (any MTLTexture)?
    private weak var canvas: BitmapCanvas?
    private var textureNeedsUpload = true

    init(device: any MTLDevice, viewColorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueFailed
        }
        self.commandQueue = queue

        let library = try device.makeLibrary(source: Self.metalSource, options: nil)
        guard let vertexFn = library.makeFunction(name: "canvas_vertex"),
              let fragmentFn = library.makeFunction(name: "canvas_fragment") else {
            throw RendererError.shaderFunctionMissing
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.colorAttachments[0].pixelFormat = viewColorPixelFormat
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.samplerFailed
        }
        self.sampler = s
    }

    func attach(canvas: BitmapCanvas) {
        self.canvas = canvas
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: canvas.width,
            height: canvas.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        canvasTexture = device.makeTexture(descriptor: descriptor)
        textureNeedsUpload = true
    }

    func canvasDidChange() {
        textureNeedsUpload = true
    }

    func render(in view: MTKView, transform: simd_float4x4) {
        guard let canvas, let texture = canvasTexture,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        if textureNeedsUpload {
            uploadCanvasToTexture(canvas: canvas, texture: texture)
            textureNeedsUpload = false
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        var uniforms = CanvasUniforms(transform: transform)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func uploadCanvasToTexture(canvas: BitmapCanvas, texture: any MTLTexture) {
        guard let data = canvas.context.data else { return }
        let region = MTLRegionMake2D(0, 0, canvas.width, canvas.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: canvas.bytesPerRow)
    }

    enum RendererError: Error, LocalizedError {
        case commandQueueFailed, shaderFunctionMissing, samplerFailed

        var errorDescription: String? {
            switch self {
            case .commandQueueFailed: "Could not create Metal command queue."
            case .shaderFunctionMissing: "Could not load shader functions."
            case .samplerFailed: "Could not create sampler state."
            }
        }
    }
}
