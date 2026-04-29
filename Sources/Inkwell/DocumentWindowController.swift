import AppKit

final class DocumentWindowController: NSWindowController {
    init(document: Document) {
        let canvasView = CanvasView(document: document)
        let brushPicker = BrushPickerView()
        let inspector = BrushInspectorView()

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 0
        container.distribution = .fill
        container.alignment = .top
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(brushPicker)
        container.addArrangedSubview(canvasView)
        container.addArrangedSubview(inspector)

        // Fix sidebar widths; canvas takes the remainder.
        brushPicker.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        inspector.translatesAutoresizingMaskIntoConstraints = false
        brushPicker.widthAnchor.constraint(equalToConstant: 130).isActive = true
        inspector.widthAnchor.constraint(equalToConstant: 280).isActive = true
        // Sidebars fill height; canvas fills both width remainder and full height.
        container.setHuggingPriority(.required, for: .horizontal)
        canvasView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1500, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            brushPicker.topAnchor.constraint(equalTo: container.topAnchor),
            brushPicker.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvasView.topAnchor.constraint(equalTo: container.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inspector.topAnchor.constraint(equalTo: container.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = host
        window.title = "Untitled"
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }
}
