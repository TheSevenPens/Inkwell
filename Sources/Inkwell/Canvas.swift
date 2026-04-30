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

/// Phase 4 document model: dimensions, Metal device + queue, and a tree of layers.
/// Replaces Phase 2's BitmapCanvas. Per-layer tile storage now lives on `BitmapLayer`.
final class Canvas {
    static let tileSize: Int = 256
    static let paperColor: SIMD4<Float> = SIMD4(0.96, 0.95, 0.92, 1.0)

    /// Mutable so document-level transforms (rotate / flip / resample) can swap
    /// dimensions on a 90° rotation, etc. Mutate only via `applyImageTransform(_:)`.
    var width: Int
    var height: Int
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue

    /// Lazily-built renderer used to rasterize vector strokes into a layer's
    /// tile cache. Shared across all vector layers in this canvas.
    private(set) lazy var ribbonRenderer: StrokeRibbonRenderer? = {
        do {
            return try StrokeRibbonRenderer(device: device, commandQueue: commandQueue)
        } catch {
            NSLog("StrokeRibbonRenderer init failed: \(error)")
            return nil
        }
    }()

    private(set) var rootLayers: [LayerNode] = []
    private(set) var activeLayerId: UUID?

    /// Whether brush input targets the active layer's mask (true) or its pixels (false).
    /// Has no effect when the active layer has no mask.
    private(set) var editingMask: Bool = false

    private(set) lazy var defaultMaskTexture: any MTLTexture = LayerMaskTextures.makeDefaultMask(device: device)

    /// Document-level selection mask. `nil` when no selection is active —
    /// stamp pipelines treat the whole canvas as selected.
    var selection: Selection?

    private var observers: [() -> Void] = []

    init(width: Int, height: Int, device: any MTLDevice) throws {
        self.width = width
        self.height = height
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw CanvasError.commandQueueFailed
        }
        self.commandQueue = queue
        let initial = BitmapLayer(
            name: "Layer 1",
            device: device,
            canvasWidth: width,
            canvasHeight: height
        )
        rootLayers = [initial]
        activeLayerId = initial.id
    }

    // MARK: - Observers

    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    /// Internal so extensions in other files (e.g. CanvasTransforms) can fire it
    /// after modifying canvas state.
    func notifyChanged() {
        observers.forEach { $0() }
    }

    // MARK: - Active layer

    var activeLayer: LayerNode? {
        guard let id = activeLayerId else { return nil }
        return findLayer(id)
    }

    var activeBitmapLayer: BitmapLayer? { activeLayer as? BitmapLayer }
    var activeVectorLayer: VectorLayer? { activeLayer as? VectorLayer }

    func setActiveLayer(_ id: UUID) {
        guard findLayer(id) != nil else { return }
        activeLayerId = id
        // If the new active layer has no mask, reset edit target to layer.
        if (findLayer(id) as? BitmapLayer)?.mask == nil {
            editingMask = false
        }
        notifyChanged()
    }

    func setEditingMask(_ flag: Bool) {
        // Only meaningful if the active layer has a mask.
        if flag, (activeBitmapLayer?.mask == nil) { return }
        guard editingMask != flag else { return }
        editingMask = flag
        notifyChanged()
    }

    /// Add a mask to the active bitmap layer. No-op if no active bitmap layer or
    /// it already has a mask.
    func addMaskToActiveLayer() {
        guard let layer = activeBitmapLayer, layer.mask == nil else { return }
        layer.mask = LayerMask(device: device, canvasWidth: width, canvasHeight: height)
        editingMask = true
        notifyChanged()
    }

    /// Remove the mask from the active bitmap layer (discards the mask data).
    func removeMaskFromActiveLayer() {
        guard let layer = activeBitmapLayer, layer.mask != nil else { return }
        layer.mask = nil
        editingMask = false
        notifyChanged()
    }

    // MARK: - Selection helpers

    /// Apply a shape operation to the selection. Creates the Selection lazily if
    /// none exists. After the op, if the selection is empty (all zero), it is
    /// discarded so stamp pipelines return to unconstrained painting.
    func applySelection(shape: [UInt8], op: Selection.Op) {
        let sel = selection ?? Selection(device: device, canvasWidth: width, canvasHeight: height)
        sel.apply(shape: shape, op: op)
        if sel.isEmpty() {
            selection = nil
        } else {
            selection = sel
        }
        notifyChanged()
    }

    func selectAll() {
        let sel = selection ?? Selection(device: device, canvasWidth: width, canvasHeight: height)
        sel.selectAll()
        selection = sel
        notifyChanged()
    }

    func deselect() {
        selection = nil
        notifyChanged()
    }

    func invertSelection() {
        if let sel = selection {
            sel.invert()
            if sel.isEmpty() {
                selection = nil
            }
            notifyChanged()
        } else {
            // No selection = nothing selected; inverse = everything selected.
            selectAll()
        }
    }

    /// Replace the selection bytes wholesale (used by the bundle loader).
    /// Discards an existing Selection and creates a fresh one if `bytes`
    /// has any non-zero pixel.
    func replaceSelectionBytes(_ bytes: [UInt8]) {
        guard bytes.count == width * height else { return }
        if bytes.allSatisfy({ $0 == 0 }) {
            selection = nil
        } else {
            let sel = Selection(device: device, canvasWidth: width, canvasHeight: height)
            sel.setBytes(bytes)
            selection = sel
        }
        notifyChanged()
    }

    /// Replace the entire layer tree, e.g. when opening a document.
    func replaceLayers(_ newRoots: [LayerNode], activeLayerId: UUID?) {
        rootLayers = newRoots
        if let activeLayerId, findInTree(activeLayerId, in: newRoots) != nil {
            self.activeLayerId = activeLayerId
        } else {
            self.activeLayerId = firstSelectableLayer()?.id
        }
        notifyChanged()
    }

    // MARK: - Tree queries

    func findLayer(_ id: UUID) -> LayerNode? {
        findInTree(id, in: rootLayers)
    }

    private func findInTree(_ id: UUID, in nodes: [LayerNode]) -> LayerNode? {
        for n in nodes {
            if n.id == id { return n }
            if let group = n as? GroupLayer, let found = findInTree(id, in: group.children) {
                return found
            }
        }
        return nil
    }

    /// Returns the parent group containing `id`, or nil if `id` is at the root.
    func parentOfLayer(_ id: UUID) -> GroupLayer? {
        parentInTree(id, parent: nil, in: rootLayers)
    }

    private func parentInTree(_ id: UUID, parent: GroupLayer?, in nodes: [LayerNode]) -> GroupLayer? {
        for n in nodes {
            if n.id == id { return parent }
            if let group = n as? GroupLayer,
               let found = parentInTree(id, parent: group, in: group.children) {
                return found
            }
        }
        return nil
    }

    private func childrenList(of parent: GroupLayer?) -> [LayerNode] {
        parent?.children ?? rootLayers
    }

    private func setChildrenList(_ list: [LayerNode], of parent: GroupLayer?) {
        if let parent = parent {
            parent.children = list
        } else {
            rootLayers = list
        }
    }

    // MARK: - Mutations

    /// Insert a new layer adjacent to the active layer (above it in stacking order).
    /// Returns the inserted layer's id.
    @discardableResult
    func addNewBitmapLayer() -> UUID {
        let layer = BitmapLayer(
            name: makeUniqueLayerName(prefix: "Layer"),
            device: device,
            canvasWidth: width,
            canvasHeight: height
        )
        insertAdjacentToActive(layer)
        activeLayerId = layer.id
        notifyChanged()
        return layer.id
    }

    @discardableResult
    func addNewBackgroundLayer() -> UUID {
        let layer = BackgroundLayer(
            name: makeUniqueLayerName(prefix: "Background"),
            color: .white
        )
        // Insert at the *bottom* of the stack so the background sits beneath
        // every other layer by default. The user can re-order via drag if
        // they want it elsewhere.
        rootLayers.append(layer)
        activeLayerId = layer.id
        notifyChanged()
        return layer.id
    }

    @discardableResult
    func addNewVectorLayer() -> UUID {
        let layer = VectorLayer(
            name: makeUniqueLayerName(prefix: "Vector"),
            device: device,
            canvasWidth: width,
            canvasHeight: height
        )
        insertAdjacentToActive(layer)
        activeLayerId = layer.id
        notifyChanged()
        return layer.id
    }

    @discardableResult
    func addNewGroup() -> UUID {
        let group = GroupLayer(name: makeUniqueLayerName(prefix: "Group"))
        insertAdjacentToActive(group)
        activeLayerId = group.id
        notifyChanged()
        return group.id
    }

    private func insertAdjacentToActive(_ node: LayerNode) {
        if let activeId = activeLayerId,
           let parent = parentOfLayer(activeId) {
            var list = parent.children
            if let idx = list.firstIndex(where: { $0.id == activeId }) {
                list.insert(node, at: idx)
            } else {
                list.insert(node, at: 0)
            }
            parent.children = list
        } else if let activeId = activeLayerId,
                  let idx = rootLayers.firstIndex(where: { $0.id == activeId }) {
            rootLayers.insert(node, at: idx)
        } else {
            rootLayers.insert(node, at: 0)
        }
    }

    func deleteLayer(_ id: UUID) {
        guard findLayer(id) != nil else { return }
        let parent = parentOfLayer(id)
        var list = childrenList(of: parent)
        list.removeAll { $0.id == id }
        setChildrenList(list, of: parent)
        if activeLayerId == id {
            activeLayerId = firstSelectableLayer()?.id
        }
        notifyChanged()
    }

    func renameLayer(_ id: UUID, to newName: String) {
        guard let layer = findLayer(id) else { return }
        layer.name = newName
        notifyChanged()
    }

    func setVisible(_ id: UUID, visible: Bool) {
        guard let layer = findLayer(id) else { return }
        layer.isVisible = visible
        notifyChanged()
    }

    func setOpacity(_ id: UUID, opacity: CGFloat) {
        guard let layer = findLayer(id) else { return }
        layer.opacity = max(0, min(1, opacity))
        notifyChanged()
    }

    func setBlendMode(_ id: UUID, mode: LayerBlendMode) {
        guard let layer = findLayer(id) else { return }
        layer.blendMode = mode
        notifyChanged()
    }

    func duplicateLayer(_ id: UUID) {
        guard let layer = findLayer(id) else { return }
        guard let bitmap = layer as? BitmapLayer else { return }
        // Phase 4: only bitmap layers are duplicable; group duplication can come later.
        let copy = BitmapLayer(
            name: bitmap.name + " copy",
            device: device,
            canvasWidth: width,
            canvasHeight: height
        )
        copy.isVisible = bitmap.isVisible
        copy.opacity = bitmap.opacity
        copy.blendMode = bitmap.blendMode
        // Copy tile bytes
        for entry in bitmap.allTiles() {
            let dest = copy.ensureTile(at: entry.coord)
            let bytes = bitmap.readTileBytes(entry.texture)
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    dest.replace(
                        region: MTLRegionMake2D(0, 0, Canvas.tileSize, Canvas.tileSize),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: Canvas.tileSize * 4
                    )
                }
            }
        }
        // Insert above the duplicated layer
        let parent = parentOfLayer(id)
        var list = childrenList(of: parent)
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list.insert(copy, at: idx)
        } else {
            list.insert(copy, at: 0)
        }
        setChildrenList(list, of: parent)
        activeLayerId = copy.id
        notifyChanged()
    }

    /// Move a layer to a new position. `newParent` nil = root. `newIndex` is its index in that list.
    func moveLayer(_ id: UUID, toIndex newIndex: Int, in newParent: GroupLayer?) {
        guard let layer = findLayer(id) else { return }
        // Disallow moving a group into itself or its descendants.
        if let group = layer as? GroupLayer,
           let target = newParent,
           descendantsContain(target, of: group) || target.id == group.id {
            return
        }
        let oldParent = parentOfLayer(id)
        var oldList = childrenList(of: oldParent)
        oldList.removeAll { $0.id == id }
        setChildrenList(oldList, of: oldParent)

        var newList = childrenList(of: newParent)
        let clampedIndex = max(0, min(newIndex, newList.count))
        newList.insert(layer, at: clampedIndex)
        setChildrenList(newList, of: newParent)
        notifyChanged()
    }

    private func descendantsContain(_ candidate: GroupLayer, of group: GroupLayer) -> Bool {
        for child in group.children {
            if let g = child as? GroupLayer {
                if g.id == candidate.id { return true }
                if descendantsContain(candidate, of: g) { return true }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func firstSelectableLayer() -> LayerNode? {
        // Prefer a leaf compositable (bitmap or vector); fall back to any layer.
        if let leaf = firstCompositable(in: rootLayers) { return leaf }
        return rootLayers.first
    }

    private func firstCompositable(in nodes: [LayerNode]) -> LayerNode? {
        for n in nodes {
            if n is CompositableLayer { return n }
            if let g = n as? GroupLayer, let found = firstCompositable(in: g.children) {
                return found
            }
        }
        return nil
    }

    private func makeUniqueLayerName(prefix: String) -> String {
        var counter = 1
        let existing = Set(allLayerNames(in: rootLayers))
        while existing.contains("\(prefix) \(counter)") { counter += 1 }
        return "\(prefix) \(counter)"
    }

    private func allLayerNames(in nodes: [LayerNode]) -> [String] {
        var names: [String] = []
        for n in nodes {
            names.append(n.name)
            if let g = n as? GroupLayer {
                names.append(contentsOf: allLayerNames(in: g.children))
            }
        }
        return names
    }

    /// Enumerate visible vector layers anywhere in the tree. Used by the
    /// vector-path debug overlay; order doesn't matter since the overlay
    /// draws on top of the composite. Hidden layers (and hidden enclosing
    /// groups) are skipped.
    func visibleVectorLayers() -> [VectorLayer] {
        var result: [VectorLayer] = []
        collectVisibleVectorLayers(in: rootLayers, into: &result)
        return result
    }

    private func collectVisibleVectorLayers(in nodes: [LayerNode], into out: inout [VectorLayer]) {
        for n in nodes {
            guard n.isVisible else { continue }
            if let v = n as? VectorLayer {
                out.append(v)
            } else if let g = n as? GroupLayer {
                collectVisibleVectorLayers(in: g.children, into: &out)
            }
        }
    }

    /// What the renderer treats as a single drawable layer. Bitmap and
    /// vector layers expose tiles via `CompositableLayer`; background
    /// layers don't — they paint as one canvas-sized quad. Unifying them
    /// in a single walk keeps stacking-order logic in one place.
    enum RenderLayer {
        case background(BackgroundLayer)
        case compositable(any CompositableLayer)
    }

    /// Walk every visible drawable leaf in compositing order (back-to-front),
    /// effective opacity multiplied through enclosing groups. Yields
    /// `BackgroundLayer`s and `CompositableLayer`s in one stream.
    func walkVisibleRenderables(_ visit: (RenderLayer, CGFloat, LayerBlendMode) -> Void) {
        walkRender(reversed: Array(rootLayers.reversed()), parentMultiplier: 1.0, visit: visit)
    }

    private func walkRender(
        reversed nodes: [LayerNode],
        parentMultiplier: CGFloat,
        visit: (RenderLayer, CGFloat, LayerBlendMode) -> Void
    ) {
        for node in nodes {
            guard node.isVisible else { continue }
            let effective = node.opacity * parentMultiplier
            if effective < 0.001 { continue }
            if let bg = node as? BackgroundLayer {
                visit(.background(bg), effective, bg.blendMode)
            } else if let compositable = node as? (any CompositableLayer) {
                visit(.compositable(compositable), effective, compositable.blendMode)
            } else if let group = node as? GroupLayer {
                walkRender(
                    reversed: Array(group.children.reversed()),
                    parentMultiplier: effective,
                    visit: visit
                )
            }
        }
    }

    /// Walk leaf compositable layers (bitmap and vector) in compositing order
    /// (back-to-front), with their effective opacity multiplied by enclosing
    /// groups (pass-through model).
    func walkVisibleCompositables(_ visit: (any CompositableLayer, CGFloat, LayerBlendMode) -> Void) {
        // rootLayers[0] is the topmost in the panel (drawn last). Iterate reversed
        // so the bottom of the stack is composited first.
        walk(reversed: Array(rootLayers.reversed()), parentMultiplier: 1.0, visit: visit)
    }

    private func walk(
        reversed nodes: [LayerNode],
        parentMultiplier: CGFloat,
        visit: (any CompositableLayer, CGFloat, LayerBlendMode) -> Void
    ) {
        for node in nodes {
            guard node.isVisible else { continue }
            let effective = node.opacity * parentMultiplier
            if effective < 0.001 { continue }
            if let compositable = node as? (any CompositableLayer) {
                visit(compositable, effective, compositable.blendMode)
            } else if let group = node as? GroupLayer {
                walk(
                    reversed: Array(group.children.reversed()),
                    parentMultiplier: effective,
                    visit: visit
                )
            }
        }
    }

    // MARK: - PNG flatten / load

    /// Composite all visible layers (CPU) into a single CGImage with paper background.
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

        walkVisibleRenderables { kind, effectiveOpacity, blendMode in
            flat.saveGState()
            flat.setBlendMode(blendMode.cgBlendMode)
            flat.setAlpha(effectiveOpacity)
            switch kind {
            case .background(let bg):
                flat.setFillColor(red: bg.color.r, green: bg.color.g, blue: bg.color.b, alpha: bg.color.a)
                flat.fill(CGRect(x: 0, y: 0, width: width, height: height))
                flat.restoreGState()
                return
            case .compositable(let layer):
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
                    flat.draw(img, in: layer.canvasRect(for: entry.coord))
                }
                flat.restoreGState()
            }
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

    /// Flatten the canvas onto an opaque background and encode as JPEG.
    /// `backgroundColor` defaults to white. `quality` is in 0…1.
    func encodeJPEGData(
        backgroundColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1),
        quality: CGFloat = 0.9
    ) throws -> Data {
        guard let composite = flattenToCGImage() else {
            throw CanvasError.flattenFailed
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info
        ) else {
            throw CanvasError.flattenFailed
        }
        ctx.setFillColor(
            red: backgroundColor.r,
            green: backgroundColor.g,
            blue: backgroundColor.b,
            alpha: 1
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(composite, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = ctx.makeImage() else {
            throw CanvasError.flattenFailed
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CanvasError.encoderCreateFailed
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, opaque, opts as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw CanvasError.encoderFinalizeFailed
        }
        return mutableData as Data
    }

    /// Encode the canvas as a flat 8-bit PSD via `PSDFormat.encodeFlat`.
    /// Pass 1: no layer hierarchy preserved — composite only.
    func encodePSDData() throws -> Data {
        guard let composite = flattenToCGImage() else {
            throw CanvasError.flattenFailed
        }
        // Render to a freshly-allocated CGContext so we can read out the bytes
        // in the exact format we want (RGBA8, premultiplied, top-down rows).
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info
        ) else {
            throw CanvasError.flattenFailed
        }
        ctx.draw(composite, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = ctx.data else { throw CanvasError.flattenFailed }
        let count = width * height * 4
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBufferPointer { buf in
            memcpy(buf.baseAddress!, raw, count)
        }
        return try PSDFormat.encodeFlat(
            width: width,
            height: height,
            premultipliedRGBA: bytes
        )
    }

    /// Load a PNG into a single new bitmap layer, replacing the current tree.
    /// Phase 5 will introduce native bundle save/load that round-trips the full tree.
    func loadPNG(from data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CanvasError.decodeFailed
        }
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
        guard let flatData = flat.data else { throw CanvasError.flattenFailed }
        let flatBytes = flatData.assumingMemoryBound(to: UInt8.self)

        // Replace the tree with a single bitmap layer holding the loaded content.
        let newLayer = BitmapLayer(
            name: "Imported",
            device: device,
            canvasWidth: width,
            canvasHeight: height
        )
        for ty in 0..<newLayer.tilesDown {
            for tx in 0..<newLayer.tilesAcross {
                var hasContent = false
                let originX = tx * Canvas.tileSize
                let originY = ty * Canvas.tileSize
                let tileW = min(Canvas.tileSize, width - originX)
                let tileH = min(Canvas.tileSize, height - originY)
                outer: for py in 0..<tileH {
                    for px in 0..<tileW {
                        let canvasX = originX + px
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
                let tex = newLayer.ensureTile(at: coord)
                var tileBytes = [UInt8](repeating: 0, count: Canvas.tileSize * Canvas.tileSize * 4)
                for py in 0..<tileH {
                    let canvasY = originY + py
                    let row = height - 1 - canvasY
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
        rootLayers = [newLayer]
        activeLayerId = newLayer.id
        notifyChanged()
    }

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

extension LayerBlendMode {
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        }
    }
}
