import AppKit

/// The application's left pane. A vertical column of collapsible sections —
/// today **Tools** (a flow-grid of brush, selection, deselect, and hand
/// icons) and **Color Palette** (HSV ring + SV square). Width is
/// user-resizable via the drag handle on its right edge; the Tools grid
/// reflows to multiple columns as the pane widens. Generic name so future
/// palettes / sections can land here without another rename.
final class LeftPaneView: NSView {
    private var stack: NSStackView!
    private var brushButtons: [NSButton] = []
    private var toolButtons: [(button: NSButton, tool: ToolState.Tool)] = []
    private var section: CollapsibleSection!
    private var colorSection: Section?
    private var colorWheel: ColorWheelView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
        BrushPalette.shared.addObserver { [weak self] in
            self?.refreshSelection()
            self?.refreshColorWheel()
        }
        ToolState.shared.addObserver { [weak self] in
            self?.refreshSelection()
        }
    }

    private func refreshColorWheel() {
        colorWheel?.setColor(BrushPalette.shared.activeBrush.color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Flip the pane's coordinate system so when it's used as the document
    /// view of an NSScrollView, content anchors to the visual top of the
    /// clip view rather than the bottom.
    override var isFlipped: Bool { true }

    private func buildLayout() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 8, bottom: 16, right: 8)
        // Leading alignment so the section header sits flush with the pane's
        // left edge (matches Brush Settings / Layers on the right). The grid
        // body is pinned to leading/trailing of the pane via explicit
        // constraints below, so it spans the full width regardless.
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Single "Tools" section holding every currently-shipped tool —
        // brushes, selection shapes, the deselect action, and the hand.
        // Future palettes / tools can live in their own sections below.
        // Collapsible via the standard disclosure-triangle header so the
        // user can hide all tools and free up vertical space when the left
        // pane is wide.
        section = CollapsibleSection(title: "Tools")
        stack.addArrangedSubview(section.header)

        // Build all the buttons in display order, then drop them into the
        // flow-grid. The grid reflows to multiple columns when the user
        // widens the left pane.
        var allButtons: [NSView] = []

        // Brushes: G-Pen, Marker, Airbrush, Eraser.
        for (idx, brush) in BrushPalette.shared.brushes.enumerated() {
            let button = makeIconButton(
                symbolName: Self.symbolName(for: brush),
                tooltip: brush.name,
                action: #selector(brushButtonClicked(_:))
            )
            button.tag = idx
            brushButtons.append(button)
            allButtons.append(button)
        }

        // Selection shapes: Rectangle, Ellipse, Lasso.
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
            toolButtons.append((button: button, tool: def.tool))
            allButtons.append(button)
        }

        // Deselect: an *action* button (not a tool toggle). Dispatched up the
        // responder chain so CanvasView.deselect(_:) handles it.
        let deselectButton = makeActionIconButton(
            symbolName: "xmark.circle",
            tooltip: "Deselect (⌘D)",
            action: #selector(CanvasView.deselect(_:))
        )
        allButtons.append(deselectButton)

        // Navigate: Hand (pan the canvas) and Move (translate the active layer).
        let handButton = makeIconButton(
            symbolName: "hand.raised.fill",
            tooltip: "Hand (Pan)",
            action: #selector(toolButtonClicked(_:))
        )
        toolButtons.append((button: handButton, tool: .hand))
        allButtons.append(handButton)

        let moveButton = makeIconButton(
            symbolName: "arrow.up.and.down.and.arrow.left.and.right",
            tooltip: "Move Layer",
            action: #selector(toolButtonClicked(_:))
        )
        toolButtons.append((button: moveButton, tool: .moveLayer))
        allButtons.append(moveButton)

        let grid = ToolsGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setButtons(allButtons)
        stack.addArrangedSubview(grid)
        section.registerBody(grid)
        // Grid spans the full content width of the pane (the stack already
        // applies its own leading/trailing insets). NSStackView with
        // `alignment = .centerX` would otherwise hand the grid a zero width
        // since it has no intrinsic width.
        grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true

        // Color Palette section — HSV ring + SV square. Bound bidirectionally
        // to BrushPalette: dragging the wheel updates the active brush's
        // color; external color changes (swatch click, hex input, eyedropper)
        // push back into the wheel via `refreshColorWheel`.
        let colorSection = Section(id: "colorPalette", title: "Color Palette")
        let wheel = ColorWheelView()
        wheel.translatesAutoresizingMaskIntoConstraints = false
        colorSection.body.addArrangedSubview(wheel)
        colorSection.install(in: stack)
        self.colorSection = colorSection  // strong ref so disclosure button's target stays alive
        self.colorWheel = wheel
        // Square that fills the pane width (minus the same 8 pt insets used
        // by the tools grid). Pinning to the LeftPaneView's leading/trailing
        // sidesteps the nested-stack alignment quirks.
        wheel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        wheel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        wheel.heightAnchor.constraint(equalTo: wheel.widthAnchor).isActive = true
        wheel.setColor(BrushPalette.shared.activeBrush.color)
        wheel.onColorChanged = { color in
            BrushPalette.shared.updateActive { $0.color = color }
        }

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
        // Frame-based sizing — `ToolsGridView` lays buttons out via setFrame
        // in its `layout()`, so we must not pin width / height through
        // autolayout (otherwise the two systems fight).
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 32)
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
        // Frame-based sizing — `ToolsGridView` lays buttons out via setFrame
        // in its `layout()`, so we must not pin width / height through
        // autolayout (otherwise the two systems fight).
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 32)
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
