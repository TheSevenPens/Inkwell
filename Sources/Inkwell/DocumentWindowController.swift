import AppKit

final class DocumentWindowController: NSWindowController {
    init(document: Document) {
        let canvasView = CanvasView(document: document)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvasView
        window.title = "Untitled"
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }
}
