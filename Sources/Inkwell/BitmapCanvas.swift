import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import simd

struct TileCoord: Hashable {
    let x: Int
    let y: Int
}

/// Phase 2: a sparse grid of fixed-size tiles, GPU-resident in unified memory.
/// Empty tiles cost nothing. Memory scales with painted area, not document size.
/// This implements the rendering decisions in ARCHITECTURE.md decision 4.
final class BitmapCanvas {
    static let tileSize: Int = 256

    let width: Int
    let height: Int
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue

    /// RGBA8 unorm sRGB-encoded values, premultiplied alpha.
    /// Empty regions of the canvas are not allocated; the renderer fills them with paper color.
    static let paperColor: SIMD4<Float> = SIMD4(0.96, 0.95, 0.92, 1.0)

    private var tiles: [TileCoord: any MTLTexture] = [:]

    init(width: Int, height: Int, device: any MTLDevice) throws {
        self.width = width
        self.height = height
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw CanvasError.commandQueueFailed
        }
        self.commandQueue = queue
    }

    var tilesAcross: Int { (width + Self.tileSize - 1) / Self.tileSize }
    var tilesDown: Int { (height + Self.tileSize - 1) / Self.tileSize }

    func tile(at coord: TileCoord) -> (any MTLTexture)? { tiles[coord] }

    func ensureTile(at coord: TileCoord) -> any MTLTexture {
        if let existing = tiles[coord] { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Self.tileSize,
            height: Self.tileSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate tile texture at \(coord)")
        }
        // Zero-initialize: empty tile is fully transparent.
        let bytesPerRow = Self.tileSize * 4
        let zero = [UInt8](repeating: 0, count: bytesPerRow * Self.tileSize)
        zero.withUnsafeBufferPointer { buf in
            tex.replace(
                region: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
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

    /// Tile coords whose canvas regions intersect the given canvas-pixel rect.
    func tilesIntersecting(_ rect: CGRect) -> [TileCoord] {
        let ts = CGFloat(Self.tileSize)
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
            x: CGFloat(coord.x * Self.tileSize),
            y: CGFloat(coord.y * Self.tileSize),
            width: CGFloat(Self.tileSize),
            height: CGFloat(Self.tileSize)
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

    private func readTileBytes(_ texture: any MTLTexture) -> Data {
        let bytesPerRow = Self.tileSize * 4
        let count = bytesPerRow * Self.tileSize
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
                mipmapLevel: 0
            )
        }
        return data
    }

    private func writeTileBytes(_ texture: any MTLTexture, data: Data) {
        let bytesPerRow = Self.tileSize * 4
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
    }

    // MARK: - PNG flatten (save/load)

    /// Composite paper background and all existing tiles into a single flat CGImage.
    func flattenToCGImage() -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let flat = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info
        ) else { return nil }
        flat.setFillColor(
            red: CGFloat(Self.paperColor.x),
            green: CGFloat(Self.paperColor.y),
            blue: CGFloat(Self.paperColor.z),
            alpha: 1.0
        )
        flat.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (coord, texture) in tiles {
            let bytes = readTileBytes(texture)
            guard let provider = CGDataProvider(data: bytes as CFData) else { continue }
            guard let image = CGImage(
                width: Self.tileSize,
                height: Self.tileSize,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Self.tileSize * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { continue }
            let rect = canvasRect(for: coord)
            flat.draw(image, in: rect)
        }
        return flat.makeImage()
    }

    func encodePNGData() throws -> Data {
        guard let image = flattenToCGImage() else {
            throw CanvasError.flattenFailed
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
        // Render the loaded image into a flat canvas-sized buffer (centered, fit).
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = width * 4
        guard let flat = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else { throw CanvasError.flattenFailed }
        // Note: leave the flat buffer fully transparent; the renderer paints paper underneath.
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let canW = CGFloat(width)
        let canH = CGFloat(height)
        let scale = min(canW / imgW, canH / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let dx = (canW - drawW) / 2.0
        let dy = (canH - drawH) / 2.0
        flat.draw(image, in: CGRect(x: dx, y: dy, width: drawW, height: drawH))
        // Replace existing tiles with content from the flat buffer.
        tiles.removeAll(keepingCapacity: true)
        guard let flatData = flat.data else { throw CanvasError.flattenFailed }
        let flatBytes = flatData.assumingMemoryBound(to: UInt8.self)
        for ty in 0..<tilesDown {
            for tx in 0..<tilesAcross {
                // Only allocate a tile if it has any non-zero alpha pixel.
                var hasContent = false
                let originX = tx * Self.tileSize
                let originY = ty * Self.tileSize
                let tileW = min(Self.tileSize, width - originX)
                let tileH = min(Self.tileSize, height - originY)
                outer: for py in 0..<tileH {
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        // Flat buffer rows are top-down; row index for canvas Y = canvasY:
                        // CG origin is bottom-left, but the data buffer is top-down, so
                        // canvas Y `cy` lives at row `height - 1 - cy`.
                        let canvasY = originY + py
                        let row = height - 1 - canvasY
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
                // Build the 256×256 tile bytes from the flat buffer.
                var tileBytes = [UInt8](repeating: 0, count: Self.tileSize * Self.tileSize * 4)
                for py in 0..<tileH {
                    let canvasY = originY + py
                    let row = height - 1 - canvasY
                    // Flat row -> tile data row. Tile data is also top-down (texture order).
                    // Tile data row for tile-pixel (px, py) is row `Self.tileSize - 1 - py`
                    // (because tile y=0 is bottom-of-tile in canvas Y-up, so it should
                    // land in the bottom row of texture data).
                    let tileRow = Self.tileSize - 1 - py
                    for px in 0..<tileW {
                        let canvasX = originX + px
                        let srcOffset = row * bytesPerRow + canvasX * 4
                        let dstOffset = tileRow * (Self.tileSize * 4) + px * 4
                        tileBytes[dstOffset + 0] = flatBytes[srcOffset + 0]
                        tileBytes[dstOffset + 1] = flatBytes[srcOffset + 1]
                        tileBytes[dstOffset + 2] = flatBytes[srcOffset + 2]
                        tileBytes[dstOffset + 3] = flatBytes[srcOffset + 3]
                    }
                }
                tileBytes.withUnsafeBufferPointer { buf in
                    tex.replace(
                        region: MTLRegionMake2D(0, 0, Self.tileSize, Self.tileSize),
                        mipmapLevel: 0,
                        withBytes: buf.baseAddress!,
                        bytesPerRow: Self.tileSize * 4
                    )
                }
            }
        }
    }

    // MARK: - Errors

    enum CanvasError: Error, LocalizedError {
        case commandQueueFailed
        case flattenFailed
        case encoderCreateFailed
        case encoderFinalizeFailed
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .commandQueueFailed: "Could not create Metal command queue."
            case .flattenFailed: "Could not flatten canvas to bitmap."
            case .encoderCreateFailed: "Could not create PNG encoder."
            case .encoderFinalizeFailed: "Could not finalize PNG encoding."
            case .decodeFailed: "Could not decode image."
            }
        }
    }
}
