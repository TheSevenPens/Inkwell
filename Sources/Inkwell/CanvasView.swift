import AppKit
import Metal
import MetalKit

@MainActor
final class CanvasView: MTKView {
    override init(frame frameRect: NSRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        configure()
    }

    convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, device: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("Not supported")
    }

    private func configure() {
        clearColor = MTLClearColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        enableSetNeedsDisplay = true
    }
}
