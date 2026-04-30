import AppKit
import Metal

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

    override class var readableTypes: [String] {
        [FileFormat.inkwellUTI, "public.png"]
    }

    override class var writableTypes: [String] {
        [FileFormat.inkwellUTI]
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
        if typeName == "public.png" {
            return try canvas.encodePNGData()
        }
        throw FileFormatError.invalidFile("Cannot write type: \(typeName)")
    }

    // MARK: - Load

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        if typeName == FileFormat.inkwellUTI {
            try canvas.deserializeFromBundle(fileWrapper)
        } else if typeName == "public.png" {
            guard let data = fileWrapper.regularFileContents else {
                throw FileFormatError.invalidFile("PNG has no content")
            }
            try canvas.loadPNG(from: data)
        } else {
            try super.read(from: fileWrapper, ofType: typeName)
        }
        onCanvasChanged?()
        undoManager?.removeAllActions()
    }

    // MARK: - Undo (per-layer per-tile, per ARCHITECTURE.md decision 9)

    func registerStrokeUndo(
        layerId: UUID,
        before: BitmapLayer.TileSnapshot,
        after: BitmapLayer.TileSnapshot
    ) {
        guard let undoManager, !before.isEmpty || !after.isEmpty else { return }
        undoManager.setActionName("Brush Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyAndRegisterInverse(layerId: layerId, snapshot: before)
        }
    }

    private func applyAndRegisterInverse(layerId: UUID, snapshot: BitmapLayer.TileSnapshot) {
        guard let layer = canvas.findLayer(layerId) as? BitmapLayer else { return }
        let affected = Set(snapshot.presentTiles.keys).union(snapshot.absentTiles)
        let previous = layer.snapshotTiles(affected)
        layer.applyTileSnapshot(snapshot)
        onCanvasChanged?()
        undoManager?.setActionName("Brush Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyAndRegisterInverse(layerId: layerId, snapshot: previous)
        }
    }
}
