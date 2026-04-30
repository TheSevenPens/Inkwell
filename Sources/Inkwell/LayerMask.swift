import Foundation
import CoreGraphics
import Metal

/// A single-channel mask attached to a `BitmapLayer`. Stored as a sparse grid of
/// `.r8Unorm` tile textures.
///
/// Convention: an **absent tile is fully white (1.0)** — i.e., the layer is fully
/// visible at that location. Only edited regions allocate tiles. The renderer
/// uses a 1×1 white texture as the default mask sample for layers without a mask
/// (or for tile coords inside a masked layer where no mask tile is allocated yet).
final class LayerMask {
    let device: any MTLDevice
    private(set) var canvasWidth: Int
    private(set) var canvasHeight: Int

    private var tiles: [TileCoord: any MTLTexture] = [:]

    init(device: any MTLDevice, canvasWidth: Int, canvasHeight: Int) {
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
            pixelFormat: .r8Unorm,
            width: Canvas.tileSize,
            height: Canvas.tileSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate mask tile at \(coord)")
        }
        // Initialize to white (.r = 255 = fully visible). Mask tiles default to
        // "everything visible" so the user sees no change until they paint.
        let bytesPerRow = Canvas.tileSize
        let white = [UInt8](repeating: 255, count: bytesPerRow * Canvas.tileSize)
        white.withUnsafeBufferPointer { buf in
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

    func allTiles() -> [(coord: TileCoord, texture: any MTLTexture)] {
        tiles.map { (coord: $0.key, texture: $0.value) }
    }

    func tilesIntersecting(_ rect: CGRect) -> [TileCoord] {
        let ts = CGFloat(Canvas.tileSize)
        let minX = max(0, Int(floor(rect.minX / ts)))
        let minY = max(0, Int(floor(rect.minY / ts)))
        let maxX = min(tilesAcross - 1, Int(floor((rect.maxX - 0.0001) / ts)))
        let maxY = min(tilesDown - 1, Int(floor((rect.maxY - 0.0001) / ts)))
        guard minX <= maxX, minY <= maxY else { return [] }
        var coords: [TileCoord] = []
        for y in minY...maxY {
            for x in minX...maxX {
                coords.append(TileCoord(x: x, y: y))
            }
        }
        return coords
    }

    // MARK: - Snapshots (for undo)

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
        let bytesPerRow = Canvas.tileSize
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
        let bytesPerRow = Canvas.tileSize
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

    // MARK: - Whole-mask rebuild (Phase 10 document transforms)

    /// Replace the mask's tile contents with a new single-channel flat image at the
    /// given dimensions. Discards existing tiles. Tiles whose entire region is fully
    /// white (255) are not allocated — that's the absent-tile convention.
    func replaceWithImage(_ image: CGImage, newWidth: Int, newHeight: Int) {
        canvasWidth = newWidth
        canvasHeight = newHeight
        tiles.removeAll(keepingCapacity: true)

        let cs = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.none.rawValue
        let bytesPerRow = newWidth
        guard let flat = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { return }
        // Initialize to white (fully visible), then overdraw with the input image.
        flat.setFillColor(gray: 1.0, alpha: 1.0)
        flat.fill(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        flat.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let flatData = flat.data else { return }
        let flatBytes = flatData.assumingMemoryBound(to: UInt8.self)

        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                let originX = tx * Canvas.tileSize
                let originY = ty * Canvas.tileSize
                let tileW = min(Canvas.tileSize, newWidth - originX)
                let tileH = min(Canvas.tileSize, newHeight - originY)
                var allWhite = true
                outer: for py in 0..<tileH {
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        let canvasY = originY + py
                        let row = newHeight - 1 - canvasY
                        let offset = row * bytesPerRow + canvasX
                        if flatBytes[offset] != 255 {
                            allWhite = false
                            break outer
                        }
                    }
                }
                guard !allWhite else { continue }
                let coord = TileCoord(x: tx, y: ty)
                let tex = ensureTile(at: coord)
                var tileBytes = [UInt8](repeating: 255, count: Canvas.tileSize * Canvas.tileSize)
                for py in 0..<tileH {
                    let canvasY = originY + py
                    let row = newHeight - 1 - canvasY
                    let tileRow = Canvas.tileSize - 1 - py
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        let srcOffset = row * bytesPerRow + canvasX
                        let dstOffset = tileRow * Canvas.tileSize + px
                        tileBytes[dstOffset] = flatBytes[srcOffset]
                    }
                }
                tileBytes.withUnsafeBufferPointer { buf in
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                        mipmapLevel: 0,
                        withBytes: buf.baseAddress!,
                        bytesPerRow: Canvas.tileSize
                    )
                }
            }
        }
    }
}

enum LayerMaskTextures {
    /// 1×1 white texture used as the fallback mask sample when a layer has no mask
    /// or no tile allocated at a given canvas region.
    static func makeDefaultMask(device: any MTLDevice) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate default mask texture")
        }
        var white: UInt8 = 255
        tex.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &white,
            bytesPerRow: 1
        )
        return tex
    }
}
