import Foundation
import CoreGraphics
import Metal

/// Document-level selection mask per ARCHITECTURE.md decision 12.
///
/// Phase 7 Pass 1 stores the selection as a single canvas-sized `.r8Unorm`
/// texture (CPU bytes mirrored, GPU uploaded on change). Tile-sparse storage
/// is a possible future optimization; the current model is simpler and the
/// memory cost (1 byte per canvas pixel ≈ 3 MB for 2048×1536) is bounded and
/// modest on Apple Silicon's unified memory.
///
/// Convention: pixel value 255 = fully selected, 0 = not selected, intermediate
/// = partial / anti-aliased edge. When `Canvas.selection` is `nil`, no selection
/// is active and stamp pipelines bind a 1×1 white default for unconstrained painting.
final class Selection {
    let device: any MTLDevice
    let canvasWidth: Int
    let canvasHeight: Int

    /// Top-down byte layout (row 0 = highest canvas Y) to match CGContext data layout
    /// and the texture upload contract.
    private(set) var bytes: [UInt8]
    private let bytesPerRow: Int
    let texture: any MTLTexture

    init(device: any MTLDevice, canvasWidth: Int, canvasHeight: Int) {
        self.device = device
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.bytesPerRow = canvasWidth
        self.bytes = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate selection texture")
        }
        self.texture = tex
        uploadAll()
    }

    /// Upload the full bytes buffer to the GPU texture.
    func uploadAll() {
        bytes.withUnsafeBufferPointer { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, canvasWidth, canvasHeight),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
    }

    /// Replace the entire byte buffer and re-upload to the GPU.
    func setBytes(_ newBytes: [UInt8]) {
        precondition(newBytes.count == bytes.count, "Wrong byte count for selection")
        bytes = newBytes
        uploadAll()
    }

    /// `true` when at least one pixel is non-zero (selection covers something).
    func isEmpty() -> Bool {
        for b in bytes where b != 0 { return false }
        return true
    }

    // MARK: - Boolean ops

    enum Op {
        case replace
        case add
        case subtract
        case intersect
    }

    /// Combine `shape` (canvas-sized .r8 bytes representing the new shape, 0..255)
    /// with the current selection per the given op.
    func apply(shape: [UInt8], op: Op) {
        precondition(shape.count == bytes.count)
        switch op {
        case .replace:
            bytes = shape
        case .add:
            for i in 0..<bytes.count {
                bytes[i] = max(bytes[i], shape[i])
            }
        case .subtract:
            for i in 0..<bytes.count {
                let s = Int(shape[i])
                let c = Int(bytes[i])
                bytes[i] = UInt8(max(0, c - s))
            }
        case .intersect:
            for i in 0..<bytes.count {
                let a = Int(bytes[i])
                let b = Int(shape[i])
                bytes[i] = UInt8((a * b + 127) / 255)
            }
        }
        uploadAll()
    }

    func clear() {
        bytes = [UInt8](repeating: 0, count: bytes.count)
        uploadAll()
    }

    func selectAll() {
        bytes = [UInt8](repeating: 255, count: bytes.count)
        uploadAll()
    }

    func invert() {
        for i in 0..<bytes.count {
            bytes[i] = 255 &- bytes[i]
        }
        uploadAll()
    }

    // MARK: - Shape rasterization (CPU)

    /// Rasterize a filled rectangle (canvas-Y-up coords) into a fresh canvas-sized
    /// .r8 buffer. The buffer is top-down to match `bytes`.
    func rasterizeRect(_ rect: CGRect) -> [UInt8] {
        let ctx = makeMaskContext()
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(rect)
        return readMaskBytes(from: ctx)
    }

    func rasterizeEllipse(in rect: CGRect) -> [UInt8] {
        let ctx = makeMaskContext()
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fillEllipse(in: rect)
        return readMaskBytes(from: ctx)
    }

    func rasterizePath(_ path: CGPath) -> [UInt8] {
        let ctx = makeMaskContext()
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.addPath(path)
        ctx.fillPath()
        return readMaskBytes(from: ctx)
    }

    private func makeMaskContext() -> CGContext {
        let cs = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth,
            space: cs,
            bitmapInfo: info
        ) else {
            fatalError("Could not create mask context")
        }
        ctx.setShouldAntialias(true)
        return ctx
    }

    private func readMaskBytes(from ctx: CGContext) -> [UInt8] {
        let count = canvasWidth * canvasHeight
        guard let data = ctx.data else { return [UInt8](repeating: 0, count: count) }
        return [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: count
        ))
    }
}
