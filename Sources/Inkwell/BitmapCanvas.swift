import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Phase 1: a single full-bitmap layer backed by a CGContext.
/// Phase 2 will replace this with a tile-based representation per ARCHITECTURE.md decision 4.
final class BitmapCanvas {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let colorSpace: CGColorSpace
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: info
        ) else {
            fatalError("Could not create canvas context")
        }
        self.context = ctx
        clearToPaper()
    }

    func clearToPaper() {
        context.saveGState()
        context.setFillColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    func stamp(_ stampImage: CGImage, at center: CGPoint, alpha: CGFloat) {
        let w = CGFloat(stampImage.width)
        let h = CGFloat(stampImage.height)
        context.saveGState()
        context.setAlpha(alpha)
        context.draw(stampImage, in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        context.restoreGState()
    }

    func makeImage() -> CGImage? {
        context.makeImage()
    }

    func snapshotPixels() -> Data {
        guard let data = context.data else { return Data() }
        return Data(bytes: data, count: height * bytesPerRow)
    }

    func restorePixels(_ snapshot: Data) {
        guard snapshot.count == height * bytesPerRow else { return }
        guard let dest = context.data else { return }
        snapshot.withUnsafeBytes { src in
            if let base = src.baseAddress {
                memcpy(dest, base, snapshot.count)
            }
        }
    }

    func encodePNGData() throws -> Data {
        guard let image = makeImage() else {
            throw CanvasError.snapshotFailed
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CanvasError.encoderCreateFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw CanvasError.encoderFinalizeFailed
        }
        return mutableData as Data
    }

    func loadPNG(from data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CanvasError.decodeFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        clearToPaper()
        // Center / fit the image into the canvas.
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let canW = CGFloat(width)
        let canH = CGFloat(height)
        let scale = min(canW / imgW, canH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let dx = (canW - drawW) / 2.0
        let dy = (canH - drawH) / 2.0
        context.draw(image, in: CGRect(x: dx, y: dy, width: drawW, height: drawH))
    }

    enum CanvasError: Error, LocalizedError {
        case snapshotFailed, encoderCreateFailed, encoderFinalizeFailed, decodeFailed

        var errorDescription: String? {
            switch self {
            case .snapshotFailed: "Could not snapshot canvas image."
            case .encoderCreateFailed: "Could not create PNG encoder."
            case .encoderFinalizeFailed: "Could not finalize PNG encoding."
            case .decodeFailed: "Could not decode image."
            }
        }
    }
}
