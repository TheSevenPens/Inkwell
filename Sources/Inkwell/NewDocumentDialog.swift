import AppKit

/// Modal dialog presented from `File → New`. The user picks a template (or
/// edits the width / height fields directly) and confirms to create a fresh
/// document at that size. Cancel returns `nil`.
///
/// Implemented as a free-standing `NSWindow` shown via `NSApp.runModal(for:)`
/// so it can run with no document window present (e.g. on first launch when
/// the document picker auto-opens, or when the user closes all docs and uses
/// the Dock-icon "+ New" affordance).
final class NewDocumentDialog: NSObject {

    /// Built-in size templates. The first ("Custom") is a sentinel — picking
    /// it means "use whatever's typed in the fields right now."
    struct Template {
        let title: String
        let size: CGSize?     // nil = Custom, just use the fields
    }

    static let templates: [Template] = [
        Template(title: "Custom", size: nil),
        Template(title: "Default — 2048 × 1536", size: CGSize(width: 2048, height: 1536)),
        Template(title: "Square Small — 1080 × 1080", size: CGSize(width: 1080, height: 1080)),
        Template(title: "Square Large — 2048 × 2048", size: CGSize(width: 2048, height: 2048)),
        Template(title: "HD 1080p — 1920 × 1080", size: CGSize(width: 1920, height: 1080)),
        Template(title: "4K UHD — 3840 × 2160", size: CGSize(width: 3840, height: 2160)),
        Template(title: "iPhone Wallpaper — 1170 × 2532", size: CGSize(width: 1170, height: 2532)),
        Template(title: "iPad Pro 12.9 — 2732 × 2048", size: CGSize(width: 2732, height: 2048)),
        Template(title: "US Letter @ 300 dpi — 2550 × 3300", size: CGSize(width: 2550, height: 3300)),
        Template(title: "A4 @ 300 dpi — 2480 × 3508", size: CGSize(width: 2480, height: 3508)),
    ]

    /// Reasonable per-axis bounds. 16384 fits within Metal's max texture
    /// dimension on Apple Silicon and avoids absurd allocations.
    private static let minDimension = 16
    private static let maxDimension = 16384

    /// The size the user chose at `init`-time defaults; updated by the
    /// fields and template pop-up while the dialog is open.
    private var pickedSize: CGSize

    private let window: NSPanel
    private let templatePopup: NSPopUpButton
    private let widthField: NSTextField
    private let heightField: NSTextField
    private let errorLabel: NSTextField
    private let createButton: NSButton

    /// True after a successful Create. Set from the button action; read by the caller.
    private(set) var didConfirm: Bool = false

    /// The size the dialog committed to (only meaningful when `didConfirm == true`).
    var confirmedSize: CGSize { pickedSize }

    init(initialSize: CGSize = Document.defaultCanvasSize) {
        self.pickedSize = initialSize

        // Build window
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Document"
        panel.isFloatingPanel = false
        self.window = panel

        // Template pop-up
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        for tpl in Self.templates {
            popup.addItem(withTitle: tpl.title)
        }
        self.templatePopup = popup

        // Width / Height fields
        widthField = NewDocumentDialog.makeIntField(initial: Int(initialSize.width))
        heightField = NewDocumentDialog.makeIntField(initial: Int(initialSize.height))

        // Error label
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let createButton = NSButton(title: "Create", target: nil, action: nil)
        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"  // Return = default
        self.createButton = createButton

        super.init()

        popup.target = self
        popup.action = #selector(templateChanged(_:))
        widthField.target = self
        widthField.action = #selector(fieldEdited(_:))
        heightField.target = self
        heightField.action = #selector(fieldEdited(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        createButton.target = self
        createButton.action = #selector(createClicked(_:))

        // Layout
        let templateLabel = NSTextField(labelWithString: "Template:")
        let widthLabel = NSTextField(labelWithString: "Width:")
        let heightLabel = NSTextField(labelWithString: "Height:")
        let pxLabelW = NSTextField(labelWithString: "px")
        let pxLabelH = NSTextField(labelWithString: "px")
        for v in [templateLabel, widthLabel, heightLabel, pxLabelW, pxLabelH] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.alignment = .right
        }

        let dimensionsRow = NSStackView()
        dimensionsRow.orientation = .horizontal
        dimensionsRow.spacing = 6
        dimensionsRow.alignment = .firstBaseline
        dimensionsRow.translatesAutoresizingMaskIntoConstraints = false
        dimensionsRow.addArrangedSubview(widthLabel)
        dimensionsRow.addArrangedSubview(widthField)
        dimensionsRow.addArrangedSubview(pxLabelW)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        dimensionsRow.addArrangedSubview(spacer)
        dimensionsRow.addArrangedSubview(heightLabel)
        dimensionsRow.addArrangedSubview(heightField)
        dimensionsRow.addArrangedSubview(pxLabelH)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(buttonSpacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(createButton)

        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .leading
        column.distribution = .fill
        column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        let templateRow = NSStackView()
        templateRow.orientation = .horizontal
        templateRow.spacing = 8
        templateRow.alignment = .firstBaseline
        templateRow.translatesAutoresizingMaskIntoConstraints = false
        templateRow.addArrangedSubview(templateLabel)
        templateRow.addArrangedSubview(popup)

        column.addArrangedSubview(templateRow)
        column.addArrangedSubview(dimensionsRow)
        column.addArrangedSubview(errorLabel)
        column.addArrangedSubview(buttonRow)

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(column)
        panel.contentView = host

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            templateLabel.widthAnchor.constraint(equalToConstant: 70),
            widthLabel.widthAnchor.constraint(equalToConstant: 50),
            heightLabel.widthAnchor.constraint(equalToConstant: 50),
            widthField.widthAnchor.constraint(equalToConstant: 70),
            heightField.widthAnchor.constraint(equalToConstant: 70),

            templateRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            templateRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            popup.trailingAnchor.constraint(equalTo: templateRow.trailingAnchor),

            dimensionsRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            dimensionsRow.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: column.trailingAnchor)
        ])

        // Default selection: pick the template that matches initialSize, or
        // fall back to "Custom" if no template matches.
        if let idx = Self.templates.firstIndex(where: { tpl in
            guard let s = tpl.size else { return false }
            return Int(s.width) == Int(initialSize.width)
                && Int(s.height) == Int(initialSize.height)
        }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)  // Custom
        }

        panel.center()
    }

    /// Run the dialog modally. Returns the chosen size on Create, or nil on Cancel.
    func runModal() -> CGSize? {
        didConfirm = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return didConfirm ? confirmedSize : nil
    }

    // MARK: - Actions

    @objc private func templateChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Self.templates.count else { return }
        guard let size = Self.templates[idx].size else { return }  // Custom: leave fields alone
        widthField.integerValue = Int(size.width)
        heightField.integerValue = Int(size.height)
        clearError()
    }

    @objc private func fieldEdited(_ sender: NSTextField) {
        // Editing fields directly switches the popup back to "Custom" unless
        // the new values exactly match a known template.
        let w = widthField.integerValue
        let h = heightField.integerValue
        if let idx = Self.templates.firstIndex(where: { tpl in
            guard let s = tpl.size else { return false }
            return Int(s.width) == w && Int(s.height) == h
        }) {
            templatePopup.selectItem(at: idx)
        } else {
            templatePopup.selectItem(at: 0)
        }
        clearError()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        didConfirm = false
        NSApp.stopModal()
    }

    @objc private func createClicked(_ sender: Any?) {
        // Force the field-editor commit before reading.
        window.makeFirstResponder(window.contentView)
        let w = widthField.integerValue
        let h = heightField.integerValue
        if !validate(width: w, height: h) { return }
        pickedSize = CGSize(width: w, height: h)
        didConfirm = true
        NSApp.stopModal()
    }

    // MARK: - Helpers

    private func validate(width: Int, height: Int) -> Bool {
        if width < Self.minDimension || height < Self.minDimension {
            showError("Width and height must be at least \(Self.minDimension) px.")
            return false
        }
        if width > Self.maxDimension || height > Self.maxDimension {
            showError("Width and height cannot exceed \(Self.maxDimension) px.")
            return false
        }
        return true
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
    }

    private func clearError() {
        errorLabel.stringValue = ""
    }

    private static func makeIntField(initial: Int) -> NSTextField {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.usesSingleLineMode = true
        field.integerValue = initial
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 100_000
        field.formatter = formatter
        return field
    }
}
