import AppKit
import Metal

final class Document: NSDocument {
    let canvas: BitmapCanvas
    var onCanvasChanged: (() -> Void)?

    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        do {
            self.canvas = try BitmapCanvas(width: 2048, height: 1536, device: device)
        } catch {
            fatalError("Could not create canvas: \(error)")
        }
        super.init()
        self.hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }

    // Phase 2 keeps PNG only. Phase 5 introduces the native .inkwell bundle.
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

    /// Per-tile delta undo per ARCHITECTURE.md decision 9.
    /// `before` describes the state of every tile that was affected by this stroke,
    /// at the moment before the first stamp landed. `after` describes the same coords
    /// at stroke commit. Either side may say "tile didn't exist" via `absentTiles`.
    func registerStrokeUndo(
        before: BitmapCanvas.TileSnapshot,
        after: BitmapCanvas.TileSnapshot
    ) {
        guard let undoManager, !before.isEmpty || !after.isEmpty else { return }
        undoManager.setActionName("Brush Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyAndRegisterInverse(snapshot: before)
        }
    }

    private func applyAndRegisterInverse(snapshot: BitmapCanvas.TileSnapshot) {
        let affected = Set(snapshot.presentTiles.keys).union(snapshot.absentTiles)
        let previous = canvas.snapshotTiles(affected)
        canvas.applyTileSnapshot(snapshot)
        onCanvasChanged?()
        undoManager?.setActionName("Brush Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyAndRegisterInverse(snapshot: previous)
        }
    }
}
