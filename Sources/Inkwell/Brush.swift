import Foundation
import CoreGraphics
import Metal
import simd

/// Codable RGBA color. Treats components as already-sRGB-encoded for Phase 3.
/// Color management arrives in Phase 11.
struct ColorRGBA: Codable, Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    var cgColor: CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    var simd: SIMD4<Float> {
        SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    static let black = ColorRGBA(r: 0, g: 0, b: 0, a: 1)
    static let white = ColorRGBA(r: 1, g: 1, b: 1, a: 1)
    static let darkInk = ColorRGBA(r: 0.04, g: 0.04, b: 0.07, a: 1)

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ cg: CGColor) {
        if let comps = cg.components, comps.count >= 3 {
            r = comps[0]; g = comps[1]; b = comps[2]
            a = comps.count >= 4 ? comps[3] : 1
        } else {
            r = 0; g = 0; b = 0; a = 1
        }
    }
}

enum BrushBlendMode: String, Codable, Equatable {
    /// Premultiplied "over" — adds paint.
    case normal
    /// Destination-out — removes paint (eraser).
    case erase
}

/// Data-driven brush definition per ARCHITECTURE.md decision 11.
/// All brushes share one engine; differences in feel come entirely from these settings.
struct Brush: Codable, Equatable {
    var id: String
    var name: String
    var category: String

    // Stamp shape
    var radius: CGFloat
    var hardness: CGFloat
    var spacing: CGFloat

    // Color & opacity
    var color: ColorRGBA
    var opacity: CGFloat

    // Pressure response
    var pressureToSize: PressureCurve
    var pressureToOpacity: PressureCurve
    /// 0 = pressure has no effect on size; 1 = effective size scales fully with pressure.
    var pressureToSizeStrength: CGFloat
    /// 0 = pressure has no effect on opacity; 1 = effective opacity scales fully with pressure.
    var pressureToOpacityStrength: CGFloat

    // Tilt response
    /// 0 = tilt has no effect on size; 1 = stamp shrinks toward zero at full tilt.
    var tiltSizeInfluence: CGFloat
    /// If true, stamp angle follows the in-plane tilt direction.
    var tiltAngleFollow: Bool

    // Per-stamp jitter
    /// 0..1 fraction. Effective size ranges in [1 - sizeJitter, 1 + sizeJitter] of base.
    var sizeJitter: CGFloat
    /// 0..1 fraction. Effective opacity ranges in [1 - opacityJitter, 1] of base.
    var opacityJitter: CGFloat

    // Behavior
    var blendMode: BrushBlendMode
    /// 0 = motion-driven (stamps emit as the stylus moves).
    /// > 0 = continuous emission while held in place at this rate (Hz). Used for Airbrush.
    var emissionHz: CGFloat
}

extension Brush {
    /// Built-in: G-Pen — hard ink pen, strong pressure response, tight spacing.
    static let gPen = Brush(
        id: "g-pen",
        name: "G-Pen",
        category: "Pens",
        radius: 6.0,
        hardness: 0.85,
        spacing: 0.05,
        color: .darkInk,
        opacity: 1.0,
        pressureToSize: .identity,
        pressureToOpacity: .identity,
        pressureToSizeStrength: 0.85,
        pressureToOpacityStrength: 0.40,
        tiltSizeInfluence: 0.0,
        tiltAngleFollow: false,
        sizeJitter: 0.0,
        opacityJitter: 0.0,
        blendMode: .normal,
        emissionHz: 0
    )

    /// Built-in: Marker — soft, translucent, layers up.
    static let marker = Brush(
        id: "marker",
        name: "Marker",
        category: "Markers",
        radius: 12.0,
        hardness: 0.45,
        spacing: 0.18,
        color: .darkInk,
        opacity: 0.55,
        pressureToSize: .identity,
        pressureToOpacity: .identity,
        pressureToSizeStrength: 0.15,
        pressureToOpacityStrength: 0.85,
        tiltSizeInfluence: 0.20,
        tiltAngleFollow: false,
        sizeJitter: 0.04,
        opacityJitter: 0.05,
        blendMode: .normal,
        emissionHz: 0
    )

    /// Built-in: Airbrush — soft, low alpha per stamp, emits continuously while held.
    static let airbrush = Brush(
        id: "airbrush",
        name: "Airbrush",
        category: "Airbrushes",
        radius: 24.0,
        hardness: 0.0,
        spacing: 0.04,
        color: .darkInk,
        opacity: 0.10,
        pressureToSize: .identity,
        pressureToOpacity: .identity,
        pressureToSizeStrength: 0.30,
        pressureToOpacityStrength: 0.95,
        tiltSizeInfluence: 0.0,
        tiltAngleFollow: false,
        sizeJitter: 0.0,
        opacityJitter: 0.15,
        blendMode: .normal,
        emissionHz: 60
    )

    /// Built-in: Eraser — same engine as Marker, removes paint instead of adding.
    static let eraser = Brush(
        id: "eraser",
        name: "Eraser",
        category: "Erasers",
        radius: 14.0,
        hardness: 0.4,
        spacing: 0.15,
        color: .black,
        opacity: 0.85,
        pressureToSize: .identity,
        pressureToOpacity: .identity,
        pressureToSizeStrength: 0.40,
        pressureToOpacityStrength: 0.60,
        tiltSizeInfluence: 0.15,
        tiltAngleFollow: false,
        sizeJitter: 0.0,
        opacityJitter: 0.0,
        blendMode: .erase,
        emissionHz: 0
    )

    static let builtins: [Brush] = [.gPen, .marker, .airbrush, .eraser]
}

extension Brush {
    /// Fixed mask resolution. The shader scales the stamp at draw time, so a single
    /// 64×64 mask covers all brush sizes without resampling artifacts at common sizes.
    static let tipPixelSize: Int = 64

    /// White RGBA mask carrying the soft-edge alpha falloff. The stamp shader colorizes at draw time.
    func makeTipMaskImage() -> CGImage {
        let size = Self.tipPixelSize
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: cs,
            bitmapInfo: info
        ) else { fatalError("Could not allocate brush tip context") }
        let center = CGPoint(x: CGFloat(size) / 2.0, y: CGFloat(size) / 2.0)
        let opaqueWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let transparentWhite = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        // hardness controls how sharp the falloff is.
        let inner = max(0.0, min(0.95, hardness))
        let gradient = CGGradient(
            colorsSpace: cs,
            colors: [opaqueWhite, transparentWhite] as CFArray,
            locations: [inner, 1.0]
        )!
        let radius = CGFloat(size) / 2.0
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
        return ctx.makeImage()!
    }

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
