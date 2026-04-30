import AppKit

final class DocumentWindowController: NSWindowController {
    private weak var brushPicker: NSView?
    private weak var rightHost: NSView?
    private var panelsHidden: Bool = false

    init(document: Document) {
        let canvasView = CanvasView(document: document)
        let brushPicker = BrushPickerView()
        let inspector = BrushInspectorView()
        let layerPanel = LayerPanelView()
        layerPanel.attach(canvas: document.canvas)

        let rightHost = NSView()
        rightHost.translatesAutoresizingMaskIntoConstraints = false
        rightHost.wantsLayer = true
        rightHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        rightHost.addSubview(inspector)
        rightHost.addSubview(layerPanel)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        layerPanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspector.topAnchor.constraint(equalTo: rightHost.topAnchor),
            inspector.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            layerPanel.topAnchor.constraint(equalTo: inspector.bottomAnchor, constant: 4),
            layerPanel.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            layerPanel.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            layerPanel.bottomAnchor.constraint(equalTo: rightHost.bottomAnchor)
        ])

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 0
        container.distribution = .fill
        container.alignment = .top
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(brushPicker)
        container.addArrangedSubview(canvasView)
        container.addArrangedSubview(rightHost)

        brushPicker.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        let pickerWidth = brushPicker.widthAnchor.constraint(equalToConstant: 130)
        pickerWidth.isActive = true
        let rightWidth = rightHost.widthAnchor.constraint(equalToConstant: 300)
        rightWidth.isActive = true
        canvasView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1500, height: 950),
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
            rightHost.topAnchor.constraint(equalTo: container.topAnchor),
            rightHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = host
        window.title = "Untitled"
        window.center()
        super.init(window: window)
        self.brushPicker = brushPicker
        self.rightHost = rightHost
        canvasView.onTogglePanels = { [weak self] in self?.togglePanels() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    func togglePanels() {
        panelsHidden.toggle()
        brushPicker?.isHidden = panelsHidden
        rightHost?.isHidden = panelsHidden
    }
}
