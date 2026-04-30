import Foundation
import CoreGraphics
import Metal

/// Document-level image transforms (Phase 10 Pass 1).
/// Resample (scaling) and resize-canvas (no-resample crop / pad) are deferred to Pass 2.
enum ImageTransform {
    case rotate180
    case rotate90CW
    case rotate90CCW
    case flipHorizontal
    case flipVertical

    var displayName: String {
        switch self {
        case .rotate180: "Rotate 180°"
        case .rotate90CW: "Rotate 90° CW"
        case .rotate90CCW: "Rotate 90° CCW"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    var swapsDimensions: Bool {
        switch self {
        case .rotate90CW, .rotate90CCW: return true
        default: return false
        }
    }

    func newDimensions(oldWidth: Int, oldHeight: Int) -> (width: Int, height: Int) {
        if swapsDimensions {
            return (oldHeight, oldWidth)
        }
        return (oldWidth, oldHeight)
    }

    /// Apply the geometric transformation to a `CGContext` whose own coordinate
    /// space is at the new dimensions; subsequent draws of the source image
    /// (positioned at `(0, 0, oldWidth, oldHeight)`) will land transformed.
    func applyToContext(_ ctx: CGContext, oldWidth: Int, oldHeight: Int) {
        let oldW = CGFloat(oldWidth)
        let oldH = CGFloat(oldHeight)
        switch self {
        case .rotate180:
            ctx.translateBy(x: oldW, y: oldH)
            ctx.rotate(by: .pi)
        case .rotate90CW:
            // newH = oldW; ctx coords are (newW=oldH × newH=oldW).
            ctx.translateBy(x: 0, y: oldW)
            ctx.rotate(by: -.pi / 2)
        case .rotate90CCW:
            // newW = oldH; ctx coords are (newW=oldH × newH=oldW).
            ctx.translateBy(x: oldH, y: 0)
            ctx.rotate(by: .pi / 2)
        case .flipHorizontal:
            ctx.translateBy(x: oldW, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: oldH)
            ctx.scaleBy(x: 1, y: -1)
        }
    }
}

extension Canvas {
    /// Apply a document-level image transform. Walks every bitmap layer (and its
    /// mask, if any) and the active selection; rebuilds tile dictionaries at the
    /// new dimensions; updates Canvas / BitmapLayer / LayerMask coordinate metadata;
    /// notifies observers.
    ///
    /// Note: this clears the undo history because per-tile snapshots from before
    /// the transform refer to coords that may no longer make sense at the new
    /// dimensions. Document-level undo is a Phase 10 Pass 2 follow-up.
    func applyImageTransform(_ kind: ImageTransform) {
        let oldW = width
        let oldH = height
        let dims = kind.newDimensions(oldWidth: oldW, oldHeight: oldH)
        let newW = dims.width
        let newH = dims.height

        // Compute the new selection bytes ahead of mutating dimensions.
        let newSelectionBytes: [UInt8]?
        if let sel = selection {
            newSelectionBytes = transformGrayBytes(
                sel.bytes,
                kind: kind,
                oldW: oldW,
                oldH: oldH,
                newW: newW,
                newH: newH
            )
        } else {
            newSelectionBytes = nil
        }

        // Walk every bitmap layer (including those nested in groups).
        for bitmap in allBitmapLayersFlat() {
            if let oldImage = renderLayerToImage(bitmap, oldW: oldW, oldH: oldH),
               let newImage = transformRGBAImage(
                oldImage,
                kind: kind,
                oldW: oldW,
                oldH: oldH,
                newW: newW,
                newH: newH
               ) {
                bitmap.replaceWithImage(newImage, newWidth: newW, newHeight: newH)
            }
            if let mask = bitmap.mask {
                if let oldMaskImage = renderMaskToImage(mask, oldW: oldW, oldH: oldH),
                   let newMaskImage = transformGrayImage(
                    oldMaskImage,
                    kind: kind,
                    oldW: oldW,
                    oldH: oldH,
                    newW: newW,
                    newH: newH
                   ) {
                    mask.replaceWithImage(newMaskImage, newWidth: newW, newHeight: newH)
                }
            }
        }

        // Update canvas dimensions BEFORE rebuilding selection so the new
        // Selection's texture is sized correctly.
        width = newW
        height = newH

        if let bytes = newSelectionBytes {
            let newSel = Selection(device: device, canvasWidth: newW, canvasHeight: newH)
            newSel.setBytes(bytes)
            selection = newSel.isEmpty() ? nil : newSel
        }

        notifyChangedAfterTransform()
    }

    // MARK: - Helpers

    /// Iterate every BitmapLayer in the tree (depth-first, root order).
    func allBitmapLayersFlat() -> [BitmapLayer] {
        var out: [BitmapLayer] = []
        func walk(_ nodes: [LayerNode]) {
            for n in nodes {
                if let b = n as? BitmapLayer { out.append(b) }
                if let g = n as? GroupLayer { walk(g.children) }
            }
        }
        walk(rootLayers)
        return out
    }

    private func renderLayerToImage(_ layer: BitmapLayer, oldW: Int, oldH: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = oldW * 4
        guard let ctx = CGContext(
            data: nil,
            width: oldW,
            height: oldH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        for entry in layer.allTiles() {
            let bytes = layer.readTileBytes(entry.texture)
            guard let provider = CGDataProvider(data: bytes as CFData) else { continue }
            guard let img = CGImage(
                width: Canvas.tileSize,
                height: Canvas.tileSize,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Canvas.tileSize * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { continue }
            ctx.draw(img, in: layer.canvasRect(for: entry.coord))
        }
        return ctx.makeImage()
    }

    private func renderMaskToImage(_ mask: LayerMask, oldW: Int, oldH: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        let bytesPerRow = oldW
        guard let ctx = CGContext(
            data: nil,
            width: oldW,
            height: oldH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        // Initialize to white — absent mask tiles are fully visible.
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: oldW, height: oldH))
        for entry in mask.allTiles() {
            let bytes = mask.readTileBytes(entry.texture)
            guard let provider = CGDataProvider(data: bytes as CFData) else { continue }
            guard let img = CGImage(
                width: Canvas.tileSize,
                height: Canvas.tileSize,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: Canvas.tileSize,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { continue }
            let rect = CGRect(
                x: entry.coord.x * Canvas.tileSize,
                y: entry.coord.y * Canvas.tileSize,
                width: Canvas.tileSize,
                height: Canvas.tileSize
            )
            ctx.draw(img, in: rect)
        }
        return ctx.makeImage()
    }

    private func transformRGBAImage(
        _ source: CGImage,
        kind: ImageTransform,
        oldW: Int, oldH: Int,
        newW: Int, newH: Int
    ) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW * 4,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        kind.applyToContext(ctx, oldWidth: oldW, oldHeight: oldH)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: oldW, height: oldH))
        return ctx.makeImage()
    }

    private func transformGrayImage(
        _ source: CGImage,
        kind: ImageTransform,
        oldW: Int, oldH: Int,
        newW: Int, newH: Int
    ) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        kind.applyToContext(ctx, oldWidth: oldW, oldHeight: oldH)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: oldW, height: oldH))
        return ctx.makeImage()
    }

    private func transformGrayBytes(
        _ bytes: [UInt8],
        kind: ImageTransform,
        oldW: Int, oldH: Int,
        newW: Int, newH: Int
    ) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let oldImage = CGImage(
                width: oldW,
                height: oldH,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: oldW,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        guard let newCtx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        kind.applyToContext(newCtx, oldWidth: oldW, oldHeight: oldH)
        newCtx.draw(oldImage, in: CGRect(x: 0, y: 0, width: oldW, height: oldH))
        guard let newData = newCtx.data else { return nil }
        let count = newW * newH
        var out = [UInt8](repeating: 0, count: count)
        _ = out.withUnsafeMutableBufferPointer { buf in
            memcpy(buf.baseAddress!, newData, count)
        }
        return out
    }

    private func notifyChangedAfterTransform() {
        notifyChanged()
    }
}
