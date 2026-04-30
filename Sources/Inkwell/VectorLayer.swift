import Foundation
import CoreGraphics
import Metal

/// A vector layer: holds an authoritative list of vector strokes plus a
/// derived sparse-tile rasterization cache. The compositor reads the cached
/// tiles via the `CompositableLayer` protocol — it doesn't need to know that
/// vectors back the layer.
///
/// Mutations route through `appendStroke` / `setStrokes` / `removeAllStrokes`
/// / `popLastStroke`, which keep the cache in sync. Direct mutation of
/// `strokes` is *not* a supported entry point.
final class VectorLayer: LayerNode, CompositableLayer {
    let id: UUID
    var name: String
    var isVisible: Bool = true
    var opacity: CGFloat = 1.0
    var blendMode: LayerBlendMode = .normal

    /// V1: vector layers do not yet support masks.
    var mask: LayerMask? { nil }

    let device: any MTLDevice
    private(set) var canvasWidth: Int
    private(set) var canvasHeight: Int

    /// Authoritative stroke list. Tiles are derived.
    private(set) var strokes: [VectorStroke] = []

    private var tiles: [TileCoord: any MTLTexture] = [:]

    init(
        id: UUID = UUID(),
        name: String = "Vector Layer",
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

    // MARK: - CompositableLayer

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
            fatalError("Could not allocate vector tile texture at \(coord)")
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

    private func clearTile(_ texture: any MTLTexture) {
        let bytesPerRow = Canvas.tileSize * 4
        let zero = [UInt8](repeating: 0, count: bytesPerRow * Canvas.tileSize)
        zero.withUnsafeBufferPointer { buf in
            texture.replace(
                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
    }

    // MARK: - Mutations

    /// Append a stroke and rasterize it into the affected tiles. Used both
    /// for finalizing a freshly-drawn stroke and for re-adding one during redo.
    @discardableResult
    func appendStroke(_ stroke: VectorStroke, ribbonRenderer: StrokeRibbonRenderer) -> Set<TileCoord> {
        strokes.append(stroke)
        return ribbonRenderer.renderStroke(stroke, into: self)
    }

    /// Replace the entire stroke list and rebuild the tile cache from scratch.
    func setStrokes(_ newStrokes: [VectorStroke], ribbonRenderer: StrokeRibbonRenderer) {
        strokes = newStrokes
        tiles.removeAll(keepingCapacity: true)
        for stroke in strokes {
            ribbonRenderer.renderStroke(stroke, into: self)
        }
    }

    /// Drop every stroke and every cached tile.
    func removeAllStrokes() {
        strokes.removeAll(keepingCapacity: false)
        tiles.removeAll(keepingCapacity: true)
    }

    /// Append a stroke without re-rasterizing. Used during file load: the
    /// strokes get attached during tree construction (no renderer available),
    /// and a single pass over all loaded vector layers rebuilds tiles afterward.
    func appendStrokeWithoutRender(_ stroke: VectorStroke) {
        strokes.append(stroke)
    }

    /// Rebuild every cached tile from the current stroke list. Used after load.
    func rebuildAllTilesFromStrokes(ribbonRenderer: StrokeRibbonRenderer) {
        tiles.removeAll(keepingCapacity: true)
        for stroke in strokes {
            ribbonRenderer.renderStroke(stroke, into: self)
        }
    }

    /// Replace strokes at the given indices with new replacement strokes
    /// (one input stroke can become 0..N outputs) and rebuild the affected
    /// tiles. Indices in `replacements` reference `strokes` *before* this
    /// call. Used by the region and to-intersection vector erasers.
    func applyStrokeReplacements(
        _ replacements: [(index: Int, with: [VectorStroke])],
        ribbonRenderer: StrokeRibbonRenderer
    ) {
        guard !replacements.isEmpty else { return }
        // Compute affected tiles: union of removed strokes' bboxes and
        // replacement strokes' bboxes.
        var affected: Set<TileCoord> = []
        for r in replacements {
            if r.index >= 0 && r.index < strokes.count {
                for c in tilesIntersecting(strokes[r.index].bounds) { affected.insert(c) }
            }
            for s in r.with {
                for c in tilesIntersecting(s.bounds) { affected.insert(c) }
            }
        }
        // Build the new strokes array preserving order. Use a dictionary
        // keyed by the *original* index; iterate the original strokes and
        // splice in replacements where applicable.
        let table = Dictionary(uniqueKeysWithValues: replacements.map { ($0.index, $0.with) })
        var newStrokes: [VectorStroke] = []
        newStrokes.reserveCapacity(strokes.count)
        for (i, s) in strokes.enumerated() {
            if let replacement = table[i] {
                newStrokes.append(contentsOf: replacement)
            } else {
                newStrokes.append(s)
            }
        }
        strokes = newStrokes
        rebuildTiles(coords: affected, ribbonRenderer: ribbonRenderer)
    }

    /// Remove the strokes at the given indices (in any order) and rebuild
    /// the tiles they had touched. Returns the set of tile coords that were
    /// rebuilt. Used by the vector eraser.
    @discardableResult
    func removeStrokes(at indices: Set<Int>, ribbonRenderer: StrokeRibbonRenderer) -> Set<TileCoord> {
        guard !indices.isEmpty else { return [] }
        // Collect affected tiles before mutation.
        var affected: Set<TileCoord> = []
        for i in indices where i >= 0 && i < strokes.count {
            for c in tilesIntersecting(strokes[i].bounds) {
                affected.insert(c)
            }
        }
        // Remove in descending index order so the remaining indices stay valid.
        for i in indices.sorted(by: >) where i >= 0 && i < strokes.count {
            strokes.remove(at: i)
        }
        rebuildTiles(coords: affected, ribbonRenderer: ribbonRenderer)
        return affected
    }

    /// Pop the last stroke and rebuild the tiles it had touched by clearing
    /// them and re-rendering every remaining stroke that overlaps any of them.
    @discardableResult
    func popLastStroke(ribbonRenderer: StrokeRibbonRenderer) -> VectorStroke? {
        guard let removed = strokes.popLast() else { return nil }
        let affected = Set(tilesIntersecting(removed.bounds))
        rebuildTiles(coords: affected, ribbonRenderer: ribbonRenderer)
        return removed
    }

    /// Clear the given tiles and re-rasterize every stroke that overlaps any
    /// of them, restricted to those tiles. Used by undo/redo and full rebuild.
    func rebuildTiles(coords: Set<TileCoord>, ribbonRenderer: StrokeRibbonRenderer) {
        for coord in coords {
            if let tex = tiles[coord] { clearTile(tex) }
        }
        for stroke in strokes {
            let strokeCoords = Set(tilesIntersecting(stroke.bounds))
            for coord in strokeCoords.intersection(coords) {
                ribbonRenderer.renderStrokeIntoTile(stroke, layer: self, coord: coord)
            }
        }
    }
}
