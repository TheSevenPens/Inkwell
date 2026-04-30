import Foundation
import CoreGraphics
import Metal

/// A bitmap layer: a sparse grid of GPU-resident tile textures, plus standard
/// per-layer attributes (visibility, opacity, blend mode). Phase 4 — only kind
/// of leaf layer that exists; vector / text / adjustment kinds arrive later.
final class BitmapLayer: LayerNode, CompositableLayer {
    let id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: CGFloat = 1.0
    var blendMode: LayerBlendMode = .normal

    let device: any MTLDevice
    /// Mutable so document-level transforms (rotate / flip / resample) can update
    /// the layer's coordinate system after rebuilding its tiles.
    private(set) var canvasWidth: Int
    private(set) var canvasHeight: Int

    /// Optional non-destructive mask. When present, painted via the same stamp
    /// pipeline targeted at the mask's `.r8Unorm` tiles; sampled at composite time
    /// to attenuate the layer's alpha.
    var mask: LayerMask?

    private var tiles: [TileCoord: any MTLTexture] = [:]

    init(
        id: UUID = UUID(),
        name: String = "Layer",
        device: any MTLDevice,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        self.id = id
        self.name = name
        self.device = device
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    var tilesAcross: Int { (canvasWidth + Canvas.tileSize - 1) / Canvas.tileSize }
    var tilesDown: Int { (canvasHeight + Canvas.tileSize - 1) / Canvas.tileSize }

    func tile(at coord: TileCoord) -> (any MTLTexture)? { tiles[coord] }

    func ensureTile(at coord: TileCoord) -> any MTLTexture {
        if let existing = tiles[coord] { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Canvas.tileSize,
            height: Canvas.tileSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate tile texture at \(coord)")
        }
        let bytesPerRow = Canvas.tileSize * 4
        let zero = [UInt8](repeating: 0, count: bytesPerRow * Canvas.tileSize)
        zero.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        tiles[coord] = tex
        return tex
    }

    func allTileCoords() -> [TileCoord] { Array(tiles.keys) }
    func allTiles() -> [(coord: TileCoord, texture: any MTLTexture)] {
        tiles.map { (coord: $0.key, texture: $0.value) }
    }

    /// Tile coords whose canvas regions intersect the given canvas-pixel rect, clamped to the canvas bounds.
    func tilesIntersecting(_ rect: CGRect) -> [TileCoord] {
        let ts = CGFloat(Canvas.tileSize)
        let minX = max(0, Int(floor(rect.minX / ts)))
        let minY = max(0, Int(floor(rect.minY / ts)))
        let maxX = min(tilesAcross - 1, Int(floor((rect.maxX - 0.0001) / ts)))
        let maxY = min(tilesDown - 1, Int(floor((rect.maxY - 0.0001) / ts)))
        guard minX <= maxX, minY <= maxY else { return [] }
        var coords: [TileCoord] = []
        coords.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                coords.append(TileCoord(x: x, y: y))
            }
        }
        return coords
    }

    func canvasRect(for coord: TileCoord) -> CGRect {
        CGRect(
            x: CGFloat(coord.x * Canvas.tileSize),
            y: CGFloat(coord.y * Canvas.tileSize),
            width: CGFloat(Canvas.tileSize),
            height: CGFloat(Canvas.tileSize)
        )
    }

    // MARK: - Per-tile snapshots (for undo per ARCHITECTURE.md decision 9)

    struct TileSnapshot {
        var presentTiles: [TileCoord: Data]
        var absentTiles: Set<TileCoord>

        static let empty = TileSnapshot(presentTiles: [:], absentTiles: [])
        var isEmpty: Bool { presentTiles.isEmpty && absentTiles.isEmpty }
    }

    func snapshotTiles(_ coords: Set<TileCoord>) -> TileSnapshot {
        var present: [TileCoord: Data] = [:]
        var absent: Set<TileCoord> = []
        for coord in coords {
            if let tex = tiles[coord] {
                present[coord] = readTileBytes(tex)
            } else {
                absent.insert(coord)
            }
        }
        return TileSnapshot(presentTiles: present, absentTiles: absent)
    }

    func applyTileSnapshot(_ snapshot: TileSnapshot) {
        for (coord, data) in snapshot.presentTiles {
            let tex = ensureTile(at: coord)
            writeTileBytes(tex, data: data)
        }
        for coord in snapshot.absentTiles {
            tiles.removeValue(forKey: coord)
        }
    }

    func readTileBytes(_ texture: any MTLTexture) -> Data {
        let bytesPerRow = Canvas.tileSize * 4
        let count = bytesPerRow * Canvas.tileSize
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                mipmapLevel: 0
            )
        }
        return data
    }

    private func writeTileBytes(_ texture: any MTLTexture, data: Data) {
        let bytesPerRow = Canvas.tileSize * 4
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
    }

    // MARK: - Whole-layer ops (Edit → Clear, etc.)

    /// Drop every tile from the layer. Sparse-tile semantics treat the result
    /// as fully transparent — this is what "no selection + clear" produces.
    func removeAllTiles() {
        tiles.removeAll(keepingCapacity: true)
    }

    /// Attenuate every pixel of one tile by `(1 − selection)`. Used by
    /// Edit → Clear when a selection is active.
    func applyClearWithinSelection(at coord: TileCoord, selection: Selection) {
        guard let texture = tiles[coord] else { return }
        var bytes = [UInt8](readTileBytes(texture))
        let selBytes = selection.bytes
        let canvasW = canvasWidth
        let canvasH = canvasHeight
        let originX = coord.x * Canvas.tileSize
        let originY = coord.y * Canvas.tileSize
        let tileW = min(Canvas.tileSize, canvasW - originX)
        let tileH = min(Canvas.tileSize, canvasH - originY)

        for py in 0..<tileH {
            // Tile data row 0 = highest canvas-Y row of the tile region.
            let canvasY = originY + (Canvas.tileSize - 1 - py)
            if canvasY < 0 || canvasY >= canvasH { continue }
            // Selection bytes are stored top-down; row 0 = canvas Y = canvasH − 1.
            let selRowOffset = (canvasH - 1 - canvasY) * canvasW
            let tileRowOffset = py * Canvas.tileSize * 4
            for px in 0..<tileW {
                let canvasX = originX + px
                if canvasX < 0 || canvasX >= canvasW { continue }
                let selByte = Int(selBytes[selRowOffset + canvasX])
                if selByte == 0 { continue }
                let inverse = 255 - selByte
                let off = tileRowOffset + px * 4
                bytes[off + 0] = UInt8((Int(bytes[off + 0]) * inverse + 127) / 255)
                bytes[off + 1] = UInt8((Int(bytes[off + 1]) * inverse + 127) / 255)
                bytes[off + 2] = UInt8((Int(bytes[off + 2]) * inverse + 127) / 255)
                bytes[off + 3] = UInt8((Int(bytes[off + 3]) * inverse + 127) / 255)
            }
        }
        bytes.withUnsafeBufferPointer { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: Canvas.tileSize * 4
            )
        }
    }

    // MARK: - Whole-layer rebuild (Phase 10 document transforms)

    /// Translate the layer's contents by an integer-pixel offset. Used by
    /// the Move Layer tool when committing a drag. Pixels that move off the
    /// canvas are clipped; new tile coords come into existence as needed.
    /// No-op if both deltas are zero.
    func translatePixels(dx: Int, dy: Int) {
        if dx == 0 && dy == 0 { return }
        // Render the current tile content into a new canvas-sized CGImage,
        // shifted by (dx, dy), then re-rasterize via replaceWithImage.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: canvasWidth * 4,
            space: cs,
            bitmapInfo: info
        ) else { return }
        // Draw existing tiles into the context at their new (shifted) rects.
        for entry in allTiles() {
            let bytes = readTileBytes(entry.texture)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let img = CGImage(
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
                  )
            else { continue }
            let r = canvasRect(for: entry.coord)
                .offsetBy(dx: CGFloat(dx), dy: CGFloat(dy))
            ctx.draw(img, in: r)
        }
        guard let translated = ctx.makeImage() else { return }
        replaceWithImage(translated, newWidth: canvasWidth, newHeight: canvasHeight)
    }

    /// Replace the layer's tile contents with a new flat image at the given dimensions.
    /// Discards the existing tile dictionary and re-allocates only tiles whose region
    /// has any non-zero alpha pixel in `image`.
    func replaceWithImage(_ image: CGImage, newWidth: Int, newHeight: Int) {
        canvasWidth = newWidth
        canvasHeight = newHeight
        tiles.removeAll(keepingCapacity: true)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = newWidth * 4
        guard let flat = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return }
        flat.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let flatData = flat.data else { return }
        let flatBytes = flatData.assumingMemoryBound(to: UInt8.self)

        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let originX = tx * Canvas.tileSize
                let originY = ty * Canvas.tileSize
                let tileW = min(Canvas.tileSize, newWidth - originX)
                let tileH = min(Canvas.tileSize, newHeight - originY)
                var hasContent = false
                outer: for py in 0..<tileH {
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        let canvasY = originY + py
                        let row = newHeight - 1 - canvasY
                        let offset = row * bytesPerRow + canvasX * 4 + 3
                        if flatBytes[offset] != 0 {
                            hasContent = true
                            break outer
                        }
                    }
                }
                guard hasContent else { continue }
                let coord = TileCoord(x: tx, y: ty)
                let tex = ensureTile(at: coord)
                var tileBytes = [UInt8](repeating: 0, count: Canvas.tileSize * Canvas.tileSize * 4)
                for py in 0..<tileH {
                    let canvasY = originY + py
                    let row = newHeight - 1 - canvasY
                    let tileRow = Canvas.tileSize - 1 - py
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        let srcOffset = row * bytesPerRow + canvasX * 4
                        let dstOffset = tileRow * (Canvas.tileSize * 4) + px * 4
                        tileBytes[dstOffset + 0] = flatBytes[srcOffset + 0]
                        tileBytes[dstOffset + 1] = flatBytes[srcOffset + 1]
                        tileBytes[dstOffset + 2] = flatBytes[srcOffset + 2]
                        tileBytes[dstOffset + 3] = flatBytes[srcOffset + 3]
                    }
                }
                tileBytes.withUnsafeBufferPointer { buf in
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                        mipmapLevel: 0,
                        withBytes: buf.baseAddress!,
                        bytesPerRow: Canvas.tileSize * 4
                    )
                }
            }
        }
    }
}
