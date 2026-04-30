import AppKit
import Metal
import UniformTypeIdentifiers

final class Document: NSDocument {
    let canvas: Canvas
    var onCanvasChanged: (() -> Void)?

    /// Default canvas dimensions for new documents created via the standard
    /// `+ New` path that bypasses the dialog (e.g. `File → Open` failure
    /// fallback, automation). The interactive `File → New` flow goes through
    /// `InkwellDocumentController.newDocument(_:)` and uses dialog values.
    static let defaultCanvasSize = CGSize(width: 2048, height: 1536)

    override convenience init() {
        self.init(canvasSize: Self.defaultCanvasSize)
    }

    init(canvasSize: CGSize) {
        let device = MTLCreateSystemDefaultDevice()!
        do {
            self.canvas = try Canvas(
                width: max(1, Int(canvasSize.width)),
                height: max(1, Int(canvasSize.height)),
                device: device
            )
        } catch {
            fatalError("Could not create canvas: \(error)")
        }
        super.init()
        self.hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }

    /// Native: `.inkwell` (read + write).
    /// Read-only: PNG / JPEG / PSD imports as a single flattened bitmap layer
    /// (PSD layer-aware import is a Phase 9 Pass 2 follow-up).
    override class var readableTypes: [String] {
        [FileFormat.inkwellUTI, "public.png", "public.jpeg", "com.adobe.photoshop-image"]
    }

    override class var writableTypes: [String] {
        [FileFormat.inkwellUTI]  // PNG / JPEG / PSD are reachable via Export, not Save.
    }

    override class func isNativeType(_ type: String) -> Bool {
        type == FileFormat.inkwellUTI
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    // MARK: - Save

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        if typeName == FileFormat.inkwellUTI {
            return try canvas.serializeToBundle()
        }
        return try super.fileWrapper(ofType: typeName)
    }

    override func data(ofType typeName: String) throws -> Data {
        // Used only for non-bundle writable types. Today writableTypes is inkwell-only,
        // but if super calls into us we still need a sensible default.
        if typeName == "public.png" {
            return try canvas.encodePNGData()
        }
        throw FileFormatError.invalidFile("Cannot write type: \(typeName)")
    }

    // MARK: - Load

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        if typeName == FileFormat.inkwellUTI {
            try canvas.deserializeFromBundle(fileWrapper)
        } else if typeName == "public.png"
                    || typeName == "public.jpeg"
                    || typeName == "com.adobe.photoshop-image" {
            guard let data = fileWrapper.regularFileContents else {
                throw FileFormatError.invalidFile("Image has no content")
            }
            // canvas.loadPNG uses CGImageSource which decodes PNG, JPEG, and PSD
            // (PSD comes back as the flattened composite). Layer-aware PSD import
            // is a Phase 9 Pass 2 follow-up.
            try canvas.loadPNG(from: data)
        } else {
            try super.read(from: fileWrapper, ofType: typeName)
        }
        onCanvasChanged?()
        undoManager?.removeAllActions()
    }

    // MARK: - Export

    @objc func exportAsPNG(_ sender: Any?) {
        runExportPanel(typeName: "PNG", contentType: .png, ext: "png") { [weak self] url in
            guard let self else { return }
            let data = try self.canvas.encodePNGData()
            try data.write(to: url, options: .atomic)
        }
    }

    @objc func exportAsJPEG(_ sender: Any?) {
        runExportPanel(typeName: "JPEG", contentType: .jpeg, ext: "jpg") { [weak self] url in
            guard let self else { return }
            let data = try self.canvas.encodeJPEGData()
            try data.write(to: url, options: .atomic)
        }
    }

    @objc func exportAsPSD(_ sender: Any?) {
        let psdType = UTType("com.adobe.photoshop-image") ?? .data
        runExportPanel(typeName: "PSD", contentType: psdType, ext: "psd") { [weak self] url in
            guard let self else { return }
            let data = try self.canvas.encodePSDData()
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Image transforms (Phase 10 Pass 1)

    @objc func imageRotate180(_ sender: Any?) { applyImageTransform(.rotate180) }
    @objc func imageRotate90CW(_ sender: Any?) { applyImageTransform(.rotate90CW) }
    @objc func imageRotate90CCW(_ sender: Any?) { applyImageTransform(.rotate90CCW) }
    @objc func imageFlipHorizontal(_ sender: Any?) { applyImageTransform(.flipHorizontal) }
    @objc func imageFlipVertical(_ sender: Any?) { applyImageTransform(.flipVertical) }

    private func applyImageTransform(_ kind: ImageTransform) {
        canvas.applyImageTransform(kind)
        // Per-tile undo snapshots from before the transform may reference
        // tiles that no longer exist at the new dimensions; clearing the
        // undo stack is the conservative choice for Pass 1. Document-level
        // undo is a Pass 2 follow-up.
        undoManager?.removeAllActions()
        updateChangeCount(.changeDone)
    }

    private func runExportPanel(
        typeName: String,
        contentType: UTType,
        ext: String,
        write: @escaping (URL) throws -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        let baseName = (displayName as String?) ?? "Untitled"
        panel.nameFieldStringValue = baseName + "." + ext
        let host = windowControllers.first?.window
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                do {
                    try write(url)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not export \(typeName)"
                    alert.runModal()
                }
            }
        }
        if let host = host {
            panel.beginSheetModal(for: host, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Edit → Clear

    /// Backspace / Delete / Edit → Clear.
    /// - With a selection active: erases the active layer's pixels (or the
    ///   active mask, if mask-edit is on) within the selection — proportional
    ///   to selection alpha.
    /// - Without a selection: drops every tile from the active layer (or
    ///   mask), which under sparse-tile semantics is equivalent to a full
    ///   clear without leaving allocated zero-valued tiles behind.
    @objc func clearAction(_ sender: Any?) {
        if let vector = canvas.activeVectorLayer {
            clearVectorContents(layer: vector)
            return
        }
        guard let layer = canvas.activeBitmapLayer else { return }
        let editingMask = canvas.editingMask && layer.mask != nil
        if editingMask, let mask = layer.mask {
            clearMaskContents(mask: mask, layerId: layer.id)
        } else {
            clearLayerContents(layer: layer)
        }
    }

    private func clearVectorContents(layer: VectorLayer) {
        let before = layer.strokes
        if before.isEmpty { return }
        layer.removeAllStrokes()
        let after: [VectorStroke] = []
        registerVectorStrokeUndo(layerId: layer.id, before: before, after: after)
        undoManager?.setActionName("Clear Layer")
        onCanvasChanged?()
        updateChangeCount(.changeDone)
    }

    private func clearLayerContents(layer: BitmapLayer) {
        let coords = Set(layer.allTiles().map { $0.coord })
        guard !coords.isEmpty else { return }
        let before = layer.snapshotTiles(coords)

        if let selection = canvas.selection {
            for coord in coords {
                layer.applyClearWithinSelection(at: coord, selection: selection)
            }
        } else {
            layer.removeAllTiles()
        }

        let after = layer.snapshotTiles(coords)
        registerLayerStrokeUndo(layerId: layer.id, before: before, after: after)
        undoManager?.setActionName(canvas.selection != nil ? "Clear Selection" : "Clear Layer")
        onCanvasChanged?()
        updateChangeCount(.changeDone)
    }

    private func clearMaskContents(mask: LayerMask, layerId: UUID) {
        let coords = Set(mask.allTiles().map { $0.coord })
        guard !coords.isEmpty else { return }
        let before = mask.snapshotTiles(coords)

        if let selection = canvas.selection {
            for coord in coords {
                mask.applyClearWithinSelection(at: coord, selection: selection)
            }
        } else {
            mask.removeAllTiles()
        }

        let after = mask.snapshotTiles(coords)
        registerMaskStrokeUndo(layerId: layerId, before: before, after: after)
        undoManager?.setActionName(canvas.selection != nil ? "Clear Selection" : "Clear Mask")
        onCanvasChanged?()
        updateChangeCount(.changeDone)
    }

    // MARK: - Undo (per ARCHITECTURE.md decision 9)

    func registerLayerStrokeUndo(
        layerId: UUID,
        before: BitmapLayer.TileSnapshot,
        after: BitmapLayer.TileSnapshot
    ) {
        guard let undoManager, !before.isEmpty || !after.isEmpty else { return }
        undoManager.setActionName("Brush Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyLayerSnapshotAndRegisterInverse(layerId: layerId, snapshot: before)
        }
    }

    private func applyLayerSnapshotAndRegisterInverse(
        layerId: UUID,
        snapshot: BitmapLayer.TileSnapshot
    ) {
        guard let layer = canvas.findLayer(layerId) as? BitmapLayer else { return }
        let affected = Set(snapshot.presentTiles.keys).union(snapshot.absentTiles)
        let previous = layer.snapshotTiles(affected)
        layer.applyTileSnapshot(snapshot)
        onCanvasChanged?()
        undoManager?.setActionName("Brush Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyLayerSnapshotAndRegisterInverse(layerId: layerId, snapshot: previous)
        }
    }

    func registerVectorStrokeUndo(
        layerId: UUID,
        before: [VectorStroke],
        after: [VectorStroke]
    ) {
        guard let undoManager else { return }
        if before == after { return }
        undoManager.setActionName("Brush Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyVectorStrokesAndRegisterInverse(layerId: layerId, strokes: before)
        }
    }

    private func applyVectorStrokesAndRegisterInverse(
        layerId: UUID,
        strokes: [VectorStroke]
    ) {
        guard let layer = canvas.findLayer(layerId) as? VectorLayer,
              let ribbonRenderer = canvas.ribbonRenderer else { return }
        let previous = layer.strokes
        layer.setStrokes(strokes, ribbonRenderer: ribbonRenderer)
        onCanvasChanged?()
        undoManager?.setActionName("Brush Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyVectorStrokesAndRegisterInverse(layerId: layerId, strokes: previous)
        }
    }

    /// Register an undo step for a selection mutation. `before` and `after`
    /// are full canvas-pixel byte arrays (or nil = no selection active).
    /// Skips registration when the two states are equal.
    func registerSelectionUndo(
        before: [UInt8]?,
        after: [UInt8]?,
        actionName: String
    ) {
        guard let undoManager else { return }
        if before == after { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applySelectionBytesAndRegisterInverse(bytes: before, actionName: actionName)
        }
    }

    private func applySelectionBytesAndRegisterInverse(bytes: [UInt8]?, actionName: String) {
        let previous = canvas.selection?.bytes
        if let bytes {
            canvas.replaceSelectionBytes(bytes)
        } else {
            canvas.deselect()
        }
        onCanvasChanged?()
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applySelectionBytesAndRegisterInverse(bytes: previous, actionName: actionName)
        }
    }

    func registerMaskStrokeUndo(
        layerId: UUID,
        before: LayerMask.TileSnapshot,
        after: LayerMask.TileSnapshot
    ) {
        guard let undoManager, !before.isEmpty || !after.isEmpty else { return }
        undoManager.setActionName("Mask Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyMaskSnapshotAndRegisterInverse(layerId: layerId, snapshot: before)
        }
    }

    private func applyMaskSnapshotAndRegisterInverse(
        layerId: UUID,
        snapshot: LayerMask.TileSnapshot
    ) {
        guard let layer = canvas.findLayer(layerId) as? BitmapLayer,
              let mask = layer.mask else { return }
        let affected = Set(snapshot.presentTiles.keys).union(snapshot.absentTiles)
        let previous = mask.snapshotTiles(affected)
        mask.applyTileSnapshot(snapshot)
        onCanvasChanged?()
        undoManager?.setActionName("Mask Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyMaskSnapshotAndRegisterInverse(layerId: layerId, snapshot: previous)
        }
    }
}
