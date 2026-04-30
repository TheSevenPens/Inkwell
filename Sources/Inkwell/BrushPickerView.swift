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

    /// Flip the picker's coordinate system so when it's used as the document
    /// view of an NSScrollView, content anchors to the visual top of the
    /// clip view rather than the bottom.
    override var isFlipped: Bool { true }

    private func buildLayout() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 8, bottom: 16, right: 8)
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stack.addArrangedSubview(sectionLabel("Brushes"))

        for (idx, brush) in BrushPalette.shared.brushes.enumerated() {
            let button = makeIconButton(
                symbolName: Self.symbolName(for: brush),
                tooltip: brush.name,
                action: #selector(brushButtonClicked(_:))
            )
            button.tag = idx
            stack.addArrangedSubview(button)
            brushButtons.append(button)
        }

        stack.addArrangedSubview(spacer(height: 8))
        stack.addArrangedSubview(sectionLabel("Selection"))

        let selectionDefs: [(symbol: String, tool: ToolState.Tool, name: String)] = [
            ("rectangle.dashed", .selectRectangle, "Rectangle Selection"),
            ("circle.dashed", .selectEllipse, "Ellipse Selection"),
            ("lasso", .selectLasso, "Lasso Selection")
        ]
        for def in selectionDefs {
            let button = makeIconButton(
                symbolName: def.symbol,
                tooltip: def.name,
                action: #selector(toolButtonClicked(_:))
            )
            stack.addArrangedSubview(button)
            toolButtons.append((button: button, tool: def.tool))
        }

        // Deselect: an *action* button (not a tool toggle). Dispatched up the
        // responder chain so CanvasView.deselect(_:) handles it.
        let deselectButton = makeActionIconButton(
            symbolName: "xmark.circle",
            tooltip: "Deselect (⌘D)",
            action: #selector(CanvasView.deselect(_:))
        )
        stack.addArrangedSubview(deselectButton)

        stack.addArrangedSubview(spacer(height: 8))
        stack.addArrangedSubview(sectionLabel("Navigate"))

        let handButton = makeIconButton(
            symbolName: "hand.raised.fill",
            tooltip: "Hand (Pan)",
            action: #selector(toolButtonClicked(_:))
        )
        stack.addArrangedSubview(handButton)
        toolButtons.append((button: handButton, tool: .hand))

        refreshSelection()
    }

    /// Momentary-press icon button that fires `action` up the responder chain
    /// (target = nil). Used for actions like Deselect, where there's no
    /// "active state" to toggle.
    private func makeActionIconButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = nil
        button.action = action
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config) {
            button.image = image
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeIconButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.bezelStyle = .regularSquare
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config) {
            button.image = image
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func spacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private static func symbolName(for brush: Brush) -> String {
        switch brush.id {
        case "g-pen": return "pencil.tip"
        case "marker": return "paintbrush.fill"
        case "airbrush": return "paintbrush.pointed.fill"
        case "eraser": return "eraser.fill"
        default: return "paintbrush"
        }
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
