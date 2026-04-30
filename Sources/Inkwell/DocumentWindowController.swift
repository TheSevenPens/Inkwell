import AppKit

/// NSView with `isFlipped = true`. Used as a documentView inside NSScrollView
/// so its content anchors at the visual top of the clip view rather than
/// the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 4 pt-wide vertical strip that the user drags horizontally. Calls
/// `onDrag` with the per-event delta-x in window points each time the
/// mouse moves while the button is held down. Shows the resize-left-right
/// cursor on hover.
private final class HorizontalDragHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: NSCursor.resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        let dx = x - dragStartX
        dragStartX = x
        if dx != 0 { onDrag?(dx) }
    }
}

final class DocumentWindowController: NSWindowController {
    private weak var leftPane: NSView?
    private weak var rightPane: NSView?
    private weak var debugBar: DebugBarView?
    private weak var canvasView: CanvasView?
    private var debugBarHeightConstraint: NSLayoutConstraint?
    private var leftPaneWidthConstraint: NSLayoutConstraint?
    private var panelsHidden: Bool = false

    private static let leftPaneWidthKey = "Inkwell.LeftPaneWidth"
    /// Bounds for the left-pane width drag. Min fits 1 column with insets;
    /// max is generous enough for a 6+ column flow grid.
    private static let leftPaneMinWidth: CGFloat = 56
    private static let leftPaneMaxWidth: CGFloat = 320

    init(document: Document) {
        let canvasView = CanvasView(document: document)
        let leftPaneInner = LeftPaneView()
        leftPaneInner.translatesAutoresizingMaskIntoConstraints = false
        // Wrap the left pane in a vertical scroll view so the window can
        // shrink below the pane's intrinsic content height (e.g. macOS
        // Window → Move & Resize → Top on a 13" display).
        let leftPane = NSScrollView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.hasVerticalScroller = true
        leftPane.hasHorizontalScroller = false
        leftPane.autohidesScrollers = true
        leftPane.borderType = .noBorder
        leftPane.drawsBackground = false
        leftPane.documentView = leftPaneInner
        leftPaneInner.widthAnchor.constraint(equalTo: leftPane.contentView.widthAnchor).isActive = true
        leftPaneInner.topAnchor.constraint(equalTo: leftPane.contentView.topAnchor).isActive = true
        let inspector = BrushInspectorView()
        let layerPanel = LayerPanelView()
        layerPanel.attach(canvas: document.canvas)
        let statusBar = StatusBarView()
        let debugBar = DebugBarView()
        debugBar.snapshotProvider = { [weak canvasView] in
            canvasView?.currentDebugSnapshot()
                ?? CanvasView.DebugSnapshot(
                    lastEventSource: .none,
                    lastEventCanvasPos: nil,
                    lastEventPressure: 0,
                    lastEventTiltX: 0,
                    lastEventTiltY: 0,
                    lastEventAzimuthDegrees: 0,
                    lastEventAltitudeDegrees: 0,
                    tabletReportsPerSecond: 0
                )
        }

        // Right pane. Wrapped in an NSScrollView so the brush inspector +
        // layer panel can stay at their intrinsic content height while the
        // window itself shrinks freely (e.g. macOS Window → Move & Resize →
        // Top, which tiles the window to half-screen height). Without the
        // scroll view, the right pane's intrinsic ~800 pt minimum would
        // refuse the resize and the window would overflow the screen.
        let rightContent = FlippedView()
        rightContent.translatesAutoresizingMaskIntoConstraints = false
        rightContent.wantsLayer = true
        rightContent.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rightContent.addSubview(inspector)
        rightContent.addSubview(layerPanel)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        layerPanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspector.topAnchor.constraint(equalTo: rightContent.topAnchor),
            inspector.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),
            layerPanel.topAnchor.constraint(equalTo: inspector.bottomAnchor, constant: 4),
            layerPanel.leadingAnchor.constraint(equalTo: rightContent.leadingAnchor),
            layerPanel.trailingAnchor.constraint(equalTo: rightContent.trailingAnchor),
            layerPanel.bottomAnchor.constraint(equalTo: rightContent.bottomAnchor)
        ])

        let rightPane = NSScrollView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.hasVerticalScroller = true
        rightPane.hasHorizontalScroller = false
        rightPane.autohidesScrollers = true
        rightPane.borderType = .noBorder
        rightPane.drawsBackground = true
        rightPane.backgroundColor = .windowBackgroundColor
        rightPane.documentView = rightContent
        // Pin the document view's width and top to the scroll view's content
        // view so there's no horizontal scroll and the document view's frame
        // is unambiguous (translatesAutoresizingMaskIntoConstraints=false
        // disables NSScrollView's automatic sizing).
        rightContent.widthAnchor.constraint(equalTo: rightPane.contentView.widthAnchor).isActive = true
        rightContent.topAnchor.constraint(equalTo: rightPane.contentView.topAnchor).isActive = true

        // Canvas area: debug bar (optional, top) + canvas (flex) + status bar (bottom).
        let canvasArea = NSView()
        canvasArea.translatesAutoresizingMaskIntoConstraints = false
        canvasArea.addSubview(debugBar)
        canvasArea.addSubview(canvasView)
        canvasArea.addSubview(statusBar)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        debugBar.translatesAutoresizingMaskIntoConstraints = false
        let debugHeight = debugBar.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            debugBar.topAnchor.constraint(equalTo: canvasArea.topAnchor),
            debugBar.leadingAnchor.constraint(equalTo: canvasArea.leadingAnchor),
            debugBar.trailingAnchor.constraint(equalTo: canvasArea.trailingAnchor),
            debugHeight,
            canvasView.topAnchor.constraint(equalTo: debugBar.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: canvasArea.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: canvasArea.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: canvasView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: canvasArea.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: canvasArea.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: canvasArea.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24)
        ])

        // Top-level horizontal container.
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 0
        container.distribution = .fill
        container.alignment = .top
        container.translatesAutoresizingMaskIntoConstraints = false
        // Drag handle sits between the left pane and the canvas — drag it
        // to resize the left pane. The Tools grid inside the pane reflows
        // its column count to match the new width.
        let leftDragHandle = HorizontalDragHandle()
        leftDragHandle.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(leftPane)
        container.addArrangedSubview(leftDragHandle)
        container.addArrangedSubview(canvasArea)
        container.addArrangedSubview(rightPane)
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        let initialLeftWidth: CGFloat = {
            let saved = UserDefaults.standard.double(forKey: Self.leftPaneWidthKey)
            if saved >= Double(Self.leftPaneMinWidth), saved <= Double(Self.leftPaneMaxWidth) {
                return CGFloat(saved)
            }
            return 72
        }()
        let leftWidthConstraint = leftPane.widthAnchor.constraint(equalToConstant: initialLeftWidth)
        leftWidthConstraint.isActive = true
        leftDragHandle.widthAnchor.constraint(equalToConstant: 4).isActive = true
        rightPane.widthAnchor.constraint(equalToConstant: 300).isActive = true
        canvasArea.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Clamp default content size to the visible screen so the window
        // doesn't extend below the dock on smaller displays. Title-bar height
        // is part of the window frame (not the content rect), so leave a
        // ~40 pt budget for it inside the visible frame too.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1500, height: 990)
        let preferredW: CGFloat = 1500
        let preferredH: CGFloat = 950
        let titleBarBudget: CGFloat = 40
        let margin: CGFloat = 12
        let contentW = min(preferredW, visible.width - margin * 2)
        let contentH = min(preferredH, visible.height - margin * 2 - titleBarBudget)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: contentW, height: contentH),
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
            leftPane.topAnchor.constraint(equalTo: container.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftDragHandle.topAnchor.constraint(equalTo: container.topAnchor),
            leftDragHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvasArea.topAnchor.constraint(equalTo: container.topAnchor),
            canvasArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightPane.topAnchor.constraint(equalTo: container.topAnchor),
            rightPane.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = host
        window.title = "Untitled"
        // Allow the window to shrink small enough to always fit on smaller
        // displays. The internal stack will compress; the user can resize up.
        window.contentMinSize = NSSize(width: 600, height: 400)
        // Center inside the *visible frame* (not the full screen frame), so
        // the dock and menu bar don't obscure the bottom / top of the window.
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            var f = window.frame
            f.origin.x = v.minX + (v.width - f.width) / 2.0
            f.origin.y = v.minY + (v.height - f.height) / 2.0
            window.setFrame(f, display: false)
        } else {
            window.center()
        }
        super.init(window: window)
        self.leftPane = leftPane
        self.rightPane = rightPane
        self.debugBar = debugBar
        self.canvasView = canvasView
        self.debugBarHeightConstraint = debugHeight
        self.leftPaneWidthConstraint = leftWidthConstraint
        leftDragHandle.onDrag = { [weak self] dx in
            self?.adjustLeftPaneWidth(by: dx)
        }
        canvasView.onTogglePanels = { [weak self] in self?.togglePanels() }
        canvasView.onStatusChanged = { [weak statusBar] snapshot in
            statusBar?.update(snapshot: snapshot)
        }
        DebugBarController.shared.addObserver { [weak self] in
            self?.applyDebugBarVisibility()
        }
        applyDebugBarVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Mutate the left-pane width constraint by `delta` (clamped to
    /// [`leftPaneMinWidth`, `leftPaneMaxWidth`]) and persist the result so
    /// the next launch opens at the same size. Called from the drag
    /// handle's `onDrag` callback.
    private func adjustLeftPaneWidth(by delta: CGFloat) {
        guard let c = leftPaneWidthConstraint else { return }
        let newWidth = max(Self.leftPaneMinWidth, min(Self.leftPaneMaxWidth, c.constant + delta))
        guard newWidth != c.constant else { return }
        c.constant = newWidth
        UserDefaults.standard.set(Double(newWidth), forKey: Self.leftPaneWidthKey)
    }

    func togglePanels() {
        panelsHidden.toggle()
        leftPane?.isHidden = panelsHidden
        rightPane?.isHidden = panelsHidden
    }

    private func applyDebugBarVisibility() {
        let visible = DebugBarController.shared.isVisible
        debugBar?.isHidden = !visible
        debugBarHeightConstraint?.constant = visible ? 26 : 0
        if visible {
            debugBar?.startRefreshing()
        } else {
            debugBar?.stopRefreshing()
        }
    }
}
