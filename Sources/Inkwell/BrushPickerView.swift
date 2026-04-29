import AppKit

final class BrushPickerView: NSView {
    private var stack: NSStackView!
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
        BrushPalette.shared.addObserver { [weak self] in
            self?.refreshSelection()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "Brush")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        for (idx, brush) in BrushPalette.shared.brushes.enumerated() {
            let button = NSButton()
            button.title = brush.name
            button.bezelStyle = .roundRect
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(brushButtonClicked(_:))
            button.tag = idx
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 100).isActive = true
            buttons.append(button)
        }
        refreshSelection()
    }

    private func refreshSelection() {
        for (idx, button) in buttons.enumerated() {
            button.state = idx == BrushPalette.shared.activeIndex ? .on : .off
        }
    }

    @objc private func brushButtonClicked(_ sender: NSButton) {
        BrushPalette.shared.setActiveIndex(sender.tag)
    }
}
