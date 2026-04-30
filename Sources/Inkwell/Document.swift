import AppKit
import Metal
import UniformTypeIdentifiers

final class Document: NSDocument {
    let canvas: Canvas
    var onCanvasChanged: (() -> Void)?

    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        do {
            self.canvas = try Canvas(width: 2048, height: 1536, device: device)
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
