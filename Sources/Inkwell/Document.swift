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

    // Phase 4 keeps PNG only; Phase 5 introduces the native .inkwell bundle that round-trips
    // the layer tree losslessly.
    override class var readableTypes: [String] { ["public.png"] }
    override class var writableTypes: [String] { ["public.png"] }

    override func makeWindowControllers() {
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    override func data(ofType typeName: String) throws -> Data {
        try canvas.encodePNGData()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        try canvas.loadPNG(from: data)
        onCanvasChanged?()
        undoManager?.removeAllActions()
    }

    /// Per-layer per-tile delta undo. `before` and `after` describe the layer's tiles
    /// at stroke start and stroke end respectively.
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
