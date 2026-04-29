import Foundation
import CoreGraphics

struct Brush {
    var radius: CGFloat = 8.0
    var hardness: CGFloat = 0.4
    var color: CGColor = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)
    var opacity: CGFloat = 1.0
    var spacing: CGFloat = 0.18
}

extension Brush {
    func makeStampImage() -> CGImage {
        let pixelDiameter = max(2, Int(ceil(radius * 2)))
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
        ) else {
            fatalError("Could not allocate brush stamp")
        }
        let center = CGPoint(x: CGFloat(pixelDiameter) / 2.0, y: CGFloat(pixelDiameter) / 2.0)
        let opaque = color.copy(alpha: 1.0) ?? color
        let transparent = color.copy(alpha: 0.0) ?? color
        let gradient = CGGradient(
            colorsSpace: cs,
            colors: [opaque, transparent] as CFArray,
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
}
