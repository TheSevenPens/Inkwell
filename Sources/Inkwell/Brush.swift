import Foundation
import CoreGraphics
import Metal
import simd

struct Brush {
    var radius: CGFloat = 8.0
    var hardness: CGFloat = 0.4
    var color: CGColor = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
    var opacity: CGFloat = 1.0
    var spacing: CGFloat = 0.18

    var tipPixelDiameter: Int { max(2, Int(ceil(radius * 2))) }

    /// Brush color as a SIMD4<Float> for the Metal shader.
    /// Phase 2 treats the components as already-sRGB-encoded (color management arrives in Phase 11).
    var colorAsSIMD: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if let comps = color.components {
            switch comps.count {
            case 4:
                r = comps[0]; g = comps[1]; b = comps[2]; a = comps[3]
            case 2:
                r = comps[0]; g = comps[0]; b = comps[0]; a = comps[1]
            default:
                break
            }
        }
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }
}

extension Brush {
    /// White RGBA mask carrying the soft-edge alpha falloff. The stamp shader colorizes at draw time.
    func makeTipMaskImage() -> CGImage {
        let pixelDiameter = tipPixelDiameter
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelDiameter,
            height: pixelDiameter,
            bitsPerComponent: 8,
            bytesPerRow: pixelDiameter * 4,
            space: cs,
            bitmapInfo: info
        ) else { fatalError("Could not allocate brush tip context") }
        let center = CGPoint(x: CGFloat(pixelDiameter) / 2.0, y: CGFloat(pixelDiameter) / 2.0)
        let opaqueWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let transparentWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        let gradient = CGGradient(
            colorsSpace: cs,
            colors: [opaqueWhite, transparentWhite] as CFArray,
            locations: [hardness, 1.0]
        )!
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
        return ctx.makeImage()!
    }

    /// Upload the tip mask to a Metal texture for the stamp shader.
    func makeTipTexture(device: any MTLDevice) -> any MTLTexture {
        let cgImage = makeTipMaskImage()
        let w = cgImage.width
        let h = cgImage.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate brush tip texture")
        }
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        bytes.withUnsafeMutableBufferPointer { buf in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = CGContext(
                data: buf.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: info
            )!
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return tex
    }
}
