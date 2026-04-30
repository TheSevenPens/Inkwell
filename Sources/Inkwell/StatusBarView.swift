import AppKit

/// Phase 11 status bar at the bottom of the canvas window.
/// Displays current zoom, view rotation (only when non-zero), the cursor's
/// canvas-pixel coordinates, and the document's pixel dimensions.
final class StatusBarView: NSView {
    private let zoomLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let docSizeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor
        docSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        docSizeLabel.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(zoomLabel)
        stack.addArrangedSubview(positionLabel)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(docSizeLabel)

        // Top-edge separator line.
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])

        update(snapshot: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    func update(snapshot: CanvasView.StatusSnapshot?) {
        guard let s = snapshot else {
            zoomLabel.stringValue = ""
            positionLabel.stringValue = ""
            docSizeLabel.stringValue = ""
            return
        }
        var zoomText = "Zoom: \(s.zoomPercent)%"
        if s.rotationDegrees != 0 {
            zoomText += "  ·  \(s.rotationDegrees)°"
        }
        zoomLabel.stringValue = zoomText
        if let p = s.canvasPosition {
            positionLabel.stringValue = String(format: "X: %.0f  Y: %.0f", p.x, p.y)
        } else {
            positionLabel.stringValue = "—"
        }
        docSizeLabel.stringValue = "\(s.documentSize.width) × \(s.documentSize.height)"
    }
}
