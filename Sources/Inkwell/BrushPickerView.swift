import AppKit

final class BrushPickerView: NSView {
    private var stack: NSStackView!
    private var brushButtons: [NSButton] = []
    private var toolButtons: [(button: NSButton, tool: ToolState.Tool)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
        BrushPalette.shared.addObserver { [weak self] in
            self?.refreshSelection()
        }
        ToolState.shared.addObserver { [weak self] in
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

        let brushTitle = NSTextField(labelWithString: "Brushes")
        brushTitle.font = .boldSystemFont(ofSize: 12)
        brushTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(brushTitle)

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
            brushButtons.append(button)
        }

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(spacer)

        let toolsTitle = NSTextField(labelWithString: "Selection")
        toolsTitle.font = .boldSystemFont(ofSize: 12)
        toolsTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(toolsTitle)

        let toolDefs: [(name: String, tool: ToolState.Tool)] = [
            ("Rectangle", .selectRectangle),
            ("Ellipse", .selectEllipse),
            ("Lasso", .selectLasso)
        ]
        for def in toolDefs {
            let button = NSButton()
            button.title = def.name
            button.bezelStyle = .roundRect
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(toolButtonClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 100).isActive = true
            toolButtons.append((button: button, tool: def.tool))
        }

        // Navigate section (Hand tool)
        let spacer2 = NSView()
        spacer2.translatesAutoresizingMaskIntoConstraints = false
        spacer2.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(spacer2)

        let navTitle = NSTextField(labelWithString: "Navigate")
        navTitle.font = .boldSystemFont(ofSize: 12)
        navTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(navTitle)

        let handButton = NSButton()
        handButton.title = "Hand"
        handButton.bezelStyle = .roundRect
        handButton.setButtonType(.pushOnPushOff)
        handButton.target = self
        handButton.action = #selector(toolButtonClicked(_:))
        handButton.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(handButton)
        handButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        toolButtons.append((button: handButton, tool: .hand))

        refreshSelection()
    }

    private func refreshSelection() {
        let toolIsBrush = ToolState.shared.tool == .brush
        for (idx, button) in brushButtons.enumerated() {
            button.state = (toolIsBrush && idx == BrushPalette.shared.activeIndex) ? .on : .off
        }
        for entry in toolButtons {
            entry.button.state = (ToolState.shared.tool == entry.tool) ? .on : .off
        }
    }

    @objc private func brushButtonClicked(_ sender: NSButton) {
        BrushPalette.shared.setActiveIndex(sender.tag)
        ToolState.shared.setTool(.brush)
    }

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard let entry = toolButtons.first(where: { $0.button === sender }) else { return }
        ToolState.shared.setTool(entry.tool)
    }
}
