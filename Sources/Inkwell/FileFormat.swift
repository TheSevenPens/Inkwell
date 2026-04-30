import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal

/// Constants and binary encoding for the `.inkwell` bundle format.
/// See `docs/FILEFORMAT.md` for the authoritative specification.
enum FileFormat {
    static let currentVersion: Int = 1

    static let manifestFilename = "manifest.json"
    static let tilesFilename = "tiles.bin"
    static let selectionFilename = "selection.bin"  // optional; absent if no active selection
    static let thumbnailFilename = "thumbnail.png"
    static let assetsDirectoryName = "assets"
    static let historyFilename = "history.bin"  // reserved; not yet written by v1 (see commit / FILEFORMAT.md)

    static let inkwellUTI = "com.thesevenpens.inkwell-document"
}

// MARK: - Manifest (JSON)

struct DocumentManifest: Codable {
    var formatVersion: Int
    var document: DocumentMetadata
    var activeLayerId: String?
    var layers: [LayerNodeData]
}

struct DocumentMetadata: Codable {
    var width: Int
    var height: Int
    var colorSpace: String   // "sRGB" for v1; "DisplayP3" reserved for the future per decision 6
}

enum LayerNodeData: Codable {
    case bitmap(BitmapLayerData)
    case group(GroupLayerData)
    case vector(VectorLayerData)

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "bitmap":
            self = .bitmap(try container.decode(BitmapLayerData.self, forKey: .data))
        case "group":
            self = .group(try container.decode(GroupLayerData.self, forKey: .data))
        case "vector":
            self = .vector(try container.decode(VectorLayerData.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown layer type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bitmap(let data):
            try container.encode("bitmap", forKey: .type)
            try container.encode(data, forKey: .data)
        case .group(let data):
            try container.encode("group", forKey: .type)
            try container.encode(data, forKey: .data)
        case .vector(let data):
            try container.encode("vector", forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }
}

struct BitmapLayerData: Codable {
    var id: String
    var name: String
    var visible: Bool
    var opacity: Double
    var blendMode: String
    /// Optional. Added in Phase 6 for layer masks; absent on Phase 5 files.
    /// Decoder treats missing as `nil` (no mask). v1 files without this field
    /// continue to load correctly.
    var hasMask: Bool?
}

struct GroupLayerData: Codable {
    var id: String
    var name: String
    var visible: Bool
    var opacity: Double
    var blendMode: String
    var expanded: Bool
    var children: [LayerNodeData]
}

/// Vector layer manifest record. Strokes are stored as JSON inline; the tile
/// cache is *not* persisted (it's re-rasterized at load), so saved vector
/// layers don't contribute records to `tiles.bin`.
struct VectorLayerData: Codable {
    var id: String
    var name: String
    var visible: Bool
    var opacity: Double
    var blendMode: String
    var strokes: [VectorStroke]
}

extension Array where Element == LayerNodeData {
    /// Walk the tree and yield every bitmap node as a `LayerNodeData.bitmap` case.
    func recursiveBitmapData() -> [LayerNodeData] {
        var out: [LayerNodeData] = []
        for node in self {
            switch node {
            case .bitmap:
                out.append(node)
            case .vector:
                continue
            case .group(let g):
                out.append(contentsOf: g.children.recursiveBitmapData())
            }
        }
        return out
    }
}

// MARK: - tiles.bin (binary)

enum TilesFile {
    static let magic: [UInt8] = Array("INKTILES".utf8)
    static let version: UInt32 = 1
    static let headerSize: Int = 16  // 8 magic + 4 version + 4 reserved
    static let keySize: Int = 32     // 16 UUID + 4 x + 4 y + 4 flags + 4 reserved
    static let lengthFieldSize: Int = 4

    struct TileRecord {
        let layerId: UUID
        let coord: TileCoord
        let isMask: Bool
        let data: Data
    }

    static func encode(_ records: [TileRecord]) -> Data {
        var out = Data()
        out.reserveCapacity(headerSize + records.count * (keySize + lengthFieldSize + Canvas.tileSize * Canvas.tileSize * 4))
        out.append(contentsOf: magic)
        out.append(uint32LE(version))
        out.append(uint32LE(0))  // reserved
        for r in records {
            out.append(uuidBytes(r.layerId))
            out.append(int32LE(Int32(r.coord.x)))
            out.append(int32LE(Int32(r.coord.y)))
            out.append(uint32LE(r.isMask ? 1 : 0))
            out.append(uint32LE(0))  // reserved
            out.append(uint32LE(UInt32(r.data.count)))
            out.append(r.data)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [TileRecord] {
        guard data.count >= headerSize else {
            throw FileFormatError.invalidFile("tiles.bin too short")
        }
        let magicBytes = [UInt8](data.subdata(in: 0..<8))
        guard magicBytes == magic else {
            throw FileFormatError.invalidFile("tiles.bin missing INKTILES magic")
        }
        let v = readUInt32LE(data, offset: 8)
        guard v == version else {
            throw FileFormatError.unsupportedVersion(Int(v))
        }
        var records: [TileRecord] = []
        var offset = headerSize
        while offset < data.count {
            guard data.count - offset >= keySize + lengthFieldSize else { break }
            let uuid = uuidFromBytes(data.subdata(in: offset..<offset + 16))
            let x = readInt32LE(data, offset: offset + 16)
            let y = readInt32LE(data, offset: offset + 20)
            let flags = readUInt32LE(data, offset: offset + 24)
            // reserved at offset+28
            let length = readUInt32LE(data, offset: offset + 32)
            offset += keySize + lengthFieldSize
            guard offset + Int(length) <= data.count else {
                throw FileFormatError.invalidFile("tiles.bin truncated record")
            }
            let tileBytes = data.subdata(in: offset..<offset + Int(length))
            offset += Int(length)
            records.append(TileRecord(
                layerId: uuid,
                coord: TileCoord(x: Int(x), y: Int(y)),
                isMask: (flags & 1) != 0,
                data: tileBytes
            ))
        }
        return records
    }
}

// MARK: - selection.bin (binary)

enum SelectionFile {
    static let magic: [UInt8] = Array("INKSELC ".utf8)  // 8 bytes
    static let version: UInt32 = 1
    static let headerSize: Int = 16  // 8 magic + 4 version + 4 reserved

    static func encode(width: Int, height: Int, bytes: [UInt8]) -> Data {
        precondition(bytes.count == width * height)
        var out = Data()
        out.reserveCapacity(headerSize + 8 + bytes.count)
        out.append(contentsOf: magic)
        out.append(uint32LE(version))
        out.append(uint32LE(0))  // reserved
        out.append(uint32LE(UInt32(width)))
        out.append(uint32LE(UInt32(height)))
        out.append(contentsOf: bytes)
        return out
    }

    /// Returns (width, height, bytes). Throws on malformed or unknown-version data.
    static func decode(_ data: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        guard data.count >= headerSize + 8 else {
            throw FileFormatError.invalidFile("selection.bin too short")
        }
        let magicBytes = [UInt8](data.subdata(in: 0..<8))
        guard magicBytes == magic else {
            throw FileFormatError.invalidFile("selection.bin missing INKSELC magic")
        }
        let v = readUInt32LE(data, offset: 8)
        guard v == version else {
            throw FileFormatError.unsupportedVersion(Int(v))
        }
        let w = Int(readUInt32LE(data, offset: 16))
        let h = Int(readUInt32LE(data, offset: 20))
        let expected = w * h
        guard data.count >= headerSize + 8 + expected else {
            throw FileFormatError.invalidFile("selection.bin pixel data truncated")
        }
        let pixelBytes = [UInt8](data.subdata(in: (headerSize + 8)..<(headerSize + 8 + expected)))
        return (w, h, pixelBytes)
    }
}

// MARK: - Errors

enum FileFormatError: Error, LocalizedError {
    case invalidFile(String)
    case unsupportedVersion(Int)
    case missingManifest
    case notABundle
    case thumbnailFailed
    case migrationRequired(from: Int, to: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let msg): return "Invalid file: \(msg)"
        case .unsupportedVersion(let v):
            return "This document was created with a newer version of Inkwell (format v\(v)). Please update."
        case .missingManifest: return "Bundle is missing manifest.json."
        case .notABundle: return "Not a valid Inkwell bundle."
        case .thumbnailFailed: return "Could not render thumbnail."
        case .migrationRequired(let from, let to):
            return "Document is in format v\(from); current is v\(to). Migration not yet implemented."
        }
    }
}

// MARK: - Migration scaffold
//
// New format versions register a migrator that reads the older manifest data and
// rewrites it as the current shape. v1 is the only version today; this is
// scaffolding for the v1→vN future.
enum FormatMigrator {
    /// Returns a manifest at `FileFormat.currentVersion`. Throws if the input is from a
    /// newer format we don't understand, or if a required migration is missing.
    static func migrate(_ raw: Data) throws -> DocumentManifest {
        // Decode just the version first.
        struct VersionProbe: Decodable {
            var formatVersion: Int
        }
        let probe = try JSONDecoder().decode(VersionProbe.self, from: raw)
        if probe.formatVersion > FileFormat.currentVersion {
            throw FileFormatError.unsupportedVersion(probe.formatVersion)
        }
        if probe.formatVersion < FileFormat.currentVersion {
            // No migrators yet; future versions will dispatch here.
            throw FileFormatError.migrationRequired(from: probe.formatVersion, to: FileFormat.currentVersion)
        }
        // Same version: decode normally.
        return try JSONDecoder().decode(DocumentManifest.self, from: raw)
    }
}

// MARK: - Helpers

private func uint32LE(_ value: UInt32) -> Data {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Data($0) }
}

private func int32LE(_ value: Int32) -> Data {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Data($0) }
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    let bytes = [UInt8](data.subdata(in: offset..<offset + 4))
    return UInt32(bytes[0])
        | (UInt32(bytes[1]) << 8)
        | (UInt32(bytes[2]) << 16)
        | (UInt32(bytes[3]) << 24)
}

private func readInt32LE(_ data: Data, offset: Int) -> Int32 {
    Int32(bitPattern: readUInt32LE(data, offset: offset))
}

private func uuidBytes(_ uuid: UUID) -> Data {
    let u = uuid.uuid
    return Data([
        u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
        u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
    ])
}

private func uuidFromBytes(_ data: Data) -> UUID {
    let bytes = [UInt8](data)
    let uuid: uuid_t = (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: uuid)
}

// MARK: - Canvas serialization

extension Canvas {
    func serializeToBundle() throws -> FileWrapper {
        let manifest = makeManifest()
        let manifestData = try jsonEncoder().encode(manifest)
        let tilesData = TilesFile.encode(collectTileRecords())
        let thumbnailData = try makeThumbnailPNG()

        var entries: [String: FileWrapper] = [
            FileFormat.manifestFilename: FileWrapper(regularFileWithContents: manifestData),
            FileFormat.tilesFilename: FileWrapper(regularFileWithContents: tilesData),
            FileFormat.thumbnailFilename: FileWrapper(regularFileWithContents: thumbnailData)
        ]
        if let selection = selection {
            let selectionData = SelectionFile.encode(
                width: width,
                height: height,
                bytes: selection.bytes
            )
            entries[FileFormat.selectionFilename] = FileWrapper(regularFileWithContents: selectionData)
        }

        // Set preferred filenames so FileWrapper writes them with the right names.
        for (name, wrapper) in entries {
            wrapper.preferredFilename = name
            entries[name] = wrapper
        }

        let bundle = FileWrapper(directoryWithFileWrappers: entries)
        return bundle
    }

    func deserializeFromBundle(_ wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw FileFormatError.notABundle
        }
        guard let manifestData = children[FileFormat.manifestFilename]?.regularFileContents else {
            throw FileFormatError.missingManifest
        }
        let manifest = try FormatMigrator.migrate(manifestData)

        // Validate dimensions match (future versions may allow on-load resize).
        guard manifest.document.width == width, manifest.document.height == height else {
            // For Phase 5 we don't allow opening into a Canvas with different dimensions.
            // The Document recreates the Canvas at the right size before calling here.
            throw FileFormatError.invalidFile(
                "Manifest dimensions \(manifest.document.width)×\(manifest.document.height) ≠ canvas \(width)×\(height)"
            )
        }

        // Build the layer tree.
        let (newRoots, idMap) = try buildLayerTree(from: manifest.layers, device: device)

        // Apply tile bytes if present.
        if let tilesRaw = children[FileFormat.tilesFilename]?.regularFileContents {
            let records = try TilesFile.decode(tilesRaw)
            for record in records {
                guard let layer = idMap[record.layerId] as? BitmapLayer else { continue }
                if record.isMask {
                    // Mask tile: 1 byte per pixel, 256×256 = 65536 bytes.
                    guard record.data.count == Canvas.tileSize * Canvas.tileSize else { continue }
                    if layer.mask == nil {
                        layer.mask = LayerMask(device: device, canvasWidth: width, canvasHeight: height)
                    }
                    let mask = layer.mask!
                    let tex = mask.ensureTile(at: record.coord)
                    record.data.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            tex.replace(
                                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                                mipmapLevel: 0,
                                withBytes: base,
                                bytesPerRow: Canvas.tileSize
                            )
                        }
                    }
                } else {
                    // Layer pixel tile: 4 bytes per pixel.
                    guard record.data.count == Canvas.tileSize * Canvas.tileSize * 4 else { continue }
                    let tex = layer.ensureTile(at: record.coord)
                    record.data.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            tex.replace(
                                region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                                mipmapLevel: 0,
                                withBytes: base,
                                bytesPerRow: Canvas.tileSize * 4
                            )
                        }
                    }
                }
            }
        }

        // For layers with hasMask but no mask tiles in tiles.bin, still attach an empty mask.
        for case .bitmap(let bd) in manifest.layers.recursiveBitmapData() {
            if bd.hasMask == true,
               let id = UUID(uuidString: bd.id),
               let layer = idMap[id] as? BitmapLayer,
               layer.mask == nil {
                layer.mask = LayerMask(device: device, canvasWidth: width, canvasHeight: height)
            }
        }

        // Rebuild vector layer tile caches now that the tree is in place.
        if let ribbonRenderer = ribbonRenderer {
            for layer in idMap.values {
                if let vector = layer as? VectorLayer {
                    vector.rebuildAllTilesFromStrokes(ribbonRenderer: ribbonRenderer)
                }
            }
        }

        let activeId = manifest.activeLayerId.flatMap { UUID(uuidString: $0) }
        replaceLayers(newRoots, activeLayerId: activeId)

        // Selection (optional)
        if let selectionRaw = children[FileFormat.selectionFilename]?.regularFileContents {
            do {
                let (sw, sh, bytes) = try SelectionFile.decode(selectionRaw)
                guard sw == width, sh == height else {
                    throw FileFormatError.invalidFile(
                        "selection.bin dimensions \(sw)×\(sh) ≠ canvas \(width)×\(height)"
                    )
                }
                replaceSelectionBytes(bytes)
            } catch {
                // Non-fatal: log and continue without a selection.
                NSLog("Could not load selection: \(error)")
            }
        }
    }

    // MARK: - Codec helpers

    private func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func makeManifest() -> DocumentManifest {
        DocumentManifest(
            formatVersion: FileFormat.currentVersion,
            document: DocumentMetadata(
                width: width,
                height: height,
                colorSpace: "sRGB"
            ),
            activeLayerId: activeLayerId?.uuidString,
            layers: rootLayers.map { layerNodeData(for: $0) }
        )
    }

    private func layerNodeData(for node: LayerNode) -> LayerNodeData {
        if let bitmap = node as? BitmapLayer {
            return .bitmap(BitmapLayerData(
                id: bitmap.id.uuidString,
                name: bitmap.name,
                visible: bitmap.isVisible,
                opacity: Double(bitmap.opacity),
                blendMode: bitmap.blendMode.rawValue,
                hasMask: bitmap.mask != nil ? true : nil
            ))
        }
        if let vector = node as? VectorLayer {
            return .vector(VectorLayerData(
                id: vector.id.uuidString,
                name: vector.name,
                visible: vector.isVisible,
                opacity: Double(vector.opacity),
                blendMode: vector.blendMode.rawValue,
                strokes: vector.strokes
            ))
        }
        if let group = node as? GroupLayer {
            return .group(GroupLayerData(
                id: group.id.uuidString,
                name: group.name,
                visible: group.isVisible,
                opacity: Double(group.opacity),
                blendMode: group.blendMode.rawValue,
                expanded: group.isExpanded,
                children: group.children.map { layerNodeData(for: $0) }
            ))
        }
        return .bitmap(BitmapLayerData(
            id: node.id.uuidString,
            name: node.name,
            visible: node.isVisible,
            opacity: Double(node.opacity),
            blendMode: node.blendMode.rawValue,
            hasMask: nil
        ))
    }

    private func collectTileRecords() -> [TilesFile.TileRecord] {
        var records: [TilesFile.TileRecord] = []
        collectTileRecords(in: rootLayers, into: &records)
        return records
    }

    private func collectTileRecords(in nodes: [LayerNode], into records: inout [TilesFile.TileRecord]) {
        for node in nodes {
            if let bitmap = node as? BitmapLayer {
                for entry in bitmap.allTiles() {
                    let bytes = bitmap.readTileBytes(entry.texture)
                    records.append(TilesFile.TileRecord(
                        layerId: bitmap.id,
                        coord: entry.coord,
                        isMask: false,
                        data: bytes
                    ))
                }
                if let mask = bitmap.mask {
                    for entry in mask.allTiles() {
                        let bytes = mask.readTileBytes(entry.texture)
                        records.append(TilesFile.TileRecord(
                            layerId: bitmap.id,
                            coord: entry.coord,
                            isMask: true,
                            data: bytes
                        ))
                    }
                }
            }
            if let group = node as? GroupLayer {
                collectTileRecords(in: group.children, into: &records)
            }
        }
    }

    private func buildLayerTree(
        from data: [LayerNodeData],
        device: any MTLDevice
    ) throws -> ([LayerNode], [UUID: LayerNode]) {
        var idMap: [UUID: LayerNode] = [:]
        let nodes = try data.map { try buildLayerNode(from: $0, device: device, idMap: &idMap) }
        return (nodes, idMap)
    }

    private func buildLayerNode(
        from data: LayerNodeData,
        device: any MTLDevice,
        idMap: inout [UUID: LayerNode]
    ) throws -> LayerNode {
        switch data {
        case .bitmap(let b):
            guard let id = UUID(uuidString: b.id) else {
                throw FileFormatError.invalidFile("Bad UUID: \(b.id)")
            }
            let layer = BitmapLayer(
                id: id,
                name: b.name,
                device: device,
                canvasWidth: width,
                canvasHeight: height
            )
            layer.isVisible = b.visible
            layer.opacity = CGFloat(b.opacity)
            layer.blendMode = LayerBlendMode(rawValue: b.blendMode) ?? .normal
            idMap[id] = layer
            return layer
        case .vector(let v):
            guard let id = UUID(uuidString: v.id) else {
                throw FileFormatError.invalidFile("Bad UUID: \(v.id)")
            }
            let layer = VectorLayer(
                id: id,
                name: v.name,
                device: device,
                canvasWidth: width,
                canvasHeight: height
            )
            layer.isVisible = v.visible
            layer.opacity = CGFloat(v.opacity)
            layer.blendMode = LayerBlendMode(rawValue: v.blendMode) ?? .normal
            // Stroke list is set here without rebuilding the tile cache; the
            // caller is responsible for re-rasterizing once a ribbon renderer
            // is available (Document.deserializeFromBundle does this).
            for stroke in v.strokes {
                layer.appendStrokeWithoutRender(stroke)
            }
            idMap[id] = layer
            return layer
        case .group(let g):
            guard let id = UUID(uuidString: g.id) else {
                throw FileFormatError.invalidFile("Bad UUID: \(g.id)")
            }
            let group = GroupLayer(id: id, name: g.name)
            group.isVisible = g.visible
            group.opacity = CGFloat(g.opacity)
            group.blendMode = LayerBlendMode(rawValue: g.blendMode) ?? .normal
            group.isExpanded = g.expanded
            for childData in g.children {
                let child = try buildLayerNode(from: childData, device: device, idMap: &idMap)
                group.children.append(child)
            }
            idMap[id] = group
            return group
        }
    }

    private func makeThumbnailPNG(maxSize: CGFloat = 512) throws -> Data {
        guard let image = flattenToCGImage() else {
            throw FileFormatError.thumbnailFailed
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let s = min(maxSize / w, maxSize / h, 1.0)
        let tw = max(1, Int(w * s))
        let th = max(1, Int(h * s))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: tw,
            height: th,
            bitsPerComponent: 8,
            bytesPerRow: tw * 4,
            space: cs,
            bitmapInfo: info
        ) else {
            throw FileFormatError.thumbnailFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let resized = ctx.makeImage() else {
            throw FileFormatError.thumbnailFailed
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FileFormatError.thumbnailFailed
        }
        CGImageDestinationAddImage(dest, resized, nil)
        if !CGImageDestinationFinalize(dest) {
            throw FileFormatError.thumbnailFailed
        }
        return mutableData as Data
    }
}
