import AppKit

final class Document: NSDocument {
    let canvas: BitmapCanvas
    var onCanvasChanged: (() -> Void)?

    override init() {
        self.canvas = BitmapCanvas(width: 2048, height: 1536)
        super.init()
        self.hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }

    // Phase 1: PNG only. Phase 5 introduces the native .inkwell bundle.
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

    func registerStrokeUndo(before: Data, after: Data) {
        guard let undoManager else { return }
        undoManager.setActionName("Brush Stroke")
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyStateAndRegisterInverse(state: before)
        }
    }

    private func applyStateAndRegisterInverse(state: Data) {
        let previous = canvas.snapshotPixels()
        canvas.restorePixels(state)
        onCanvasChanged?()
        undoManager?.setActionName("Brush Stroke")
        undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.applyStateAndRegisterInverse(state: previous)
        }
    }
}
