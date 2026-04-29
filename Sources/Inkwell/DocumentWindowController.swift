import AppKit

@MainActor
final class DocumentWindowController: NSWindowController {
    init() {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.title = "Untitled"
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }
}
