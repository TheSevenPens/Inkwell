import AppKit

/// Right-sidebar inspector: live editing of the active brush's settings.
final class BrushInspectorView: NSView {
    private var stack: NSStackView!
    private var nameLabel: NSTextField!
    private var rows: [String: SliderRow] = [:]
    private var colorWell: NSColorWell!
    private var hexField: NSTextField!
    private var refreshing = false
    private var section: CollapsibleSection!

    /// Built-in swatch palette. Phase 11 Pass 1 ships these only; user-saved
    /// swatches are a follow-up.
    private static let builtinSwatches: [ColorRGBA] = [
        ColorRGBA(r: 0.00, g: 0.00, b: 0.00),  // black
        ColorRGBA(r: 0.30, g: 0.30, b: 0.30),  // dark gray
        ColorRGBA(r: 0.65, g: 0.65, b: 0.65),  // light gray
        ColorRGBA(r: 1.00, g: 1.00, b: 1.00),  // white
        ColorRGBA(r: 0.85, g: 0.10, b: 0.10),  // red
        ColorRGBA(r: 0.95, g: 0.55, b: 0.10),  // orange
        ColorRGBA(r: 0.95, g: 0.85, b: 0.20),  // yellow
        ColorRGBA(r: 0.20, g: 0.65, b: 0.25),  // green
        ColorRGBA(r: 0.10, g: 0.40, b: 0.85),  // blue
        ColorRGBA(r: 0.55, g: 0.20, b: 0.75),  // purple
        ColorRGBA(r: 0.85, g: 0.45, b: 0.65),  // pink
        ColorRGBA(r: 0.45, g: 0.30, b: 0.15)   // brown
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
        BrushPalette.shared.addObserver { [weak self] in
            self?.refreshFromBrush()
        }
        refreshFromBrush()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
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

        section = CollapsibleSection(title: "Brush Settings")
        stack.addArrangedSubview(section.header)

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        section.add(nameLabel, to: stack)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        let colorLabel = NSTextField(labelWithString: "Color")
        colorLabel.font = NSFont.systemFont(ofSize: 12)
        colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true

        hexField = NSTextField()
        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.placeholderString = "#000000"
        hexField.target = self
        hexField.action = #selector(hexChanged(_:))
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        colorRow.addArrangedSubview(colorLabel)
        colorRow.addArrangedSubview(colorWell)
        colorRow.addArrangedSubview(hexField)
        section.add(colorRow, to: stack)

        // Swatches: 12 built-in colors in a single row.
        let swatchRow = NSStackView()
        swatchRow.orientation = .horizontal
        swatchRow.spacing = 2
        swatchRow.alignment = .centerY
        for color in Self.builtinSwatches {
            let button = SwatchButton(color: color)
            button.target = self
            button.action = #selector(swatchClicked(_:))
            swatchRow.addArrangedSubview(button)
        }
        section.add(swatchRow, to: stack)

        addSliderRow(key: "size", label: "Size", min: 1, max: 80, fmt: "%.1f")
        addSliderRow(key: "hardness", label: "Hardness", min: 0, max: 1, fmt: "%.2f")
        addSliderRow(key: "spacing", label: "Spacing", min: 0.02, max: 0.6, fmt: "%.2f")
        addSliderRow(key: "opacity", label: "Opacity", min: 0, max: 1, fmt: "%.2f")
        section.add(thinRule(), to: stack)
        addSliderRow(key: "p2size", label: "Press → Size", min: 0, max: 1, fmt: "%.2f")
        addSliderRow(key: "p2alpha", label: "Press → Opacity", min: 0, max: 1, fmt: "%.2f")
        section.add(thinRule(), to: stack)
        addSliderRow(key: "tiltSize", label: "Tilt → Size", min: 0, max: 1, fmt: "%.2f")
        addSliderRow(key: "sizeJitter", label: "Size Jitter", min: 0, max: 0.5, fmt: "%.2f")
        addSliderRow(key: "alphaJitter", label: "Opacity Jitter", min: 0, max: 0.5, fmt: "%.2f")
    }

    private func addSliderRow(key: String, label: String, min: Double, max: Double, fmt: String) {
        let row = SliderRow(label: label, min: min, max: max, fmt: fmt)
        row.onChange = { [weak self] value in
            guard let self, !self.refreshing else { return }
            BrushPalette.shared.updateActive { brush in
                self.applySliderUpdate(key: key, value: value, into: &brush)
            }
        }
        rows[key] = row
        section.add(row, to: stack)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    private func applySliderUpdate(key: String, value: Double, into brush: inout Brush) {
        switch key {
        case "size": brush.radius = CGFloat(value)
        case "hardness": brush.hardness = CGFloat(value)
        case "spacing": brush.spacing = CGFloat(value)
        case "opacity": brush.opacity = CGFloat(value)
        case "p2size": brush.pressureToSizeStrength = CGFloat(value)
        case "p2alpha": brush.pressureToOpacityStrength = CGFloat(value)
        case "tiltSize": brush.tiltSizeInfluence = CGFloat(value)
        case "sizeJitter": brush.sizeJitter = CGFloat(value)
        case "alphaJitter": brush.opacityJitter = CGFloat(value)
        default: break
        }
    }

    private func thinRule() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func refreshFromBrush() {
        let b = BrushPalette.shared.activeBrush
        refreshing = true
        defer { refreshing = false }
        nameLabel.stringValue = b.name
        let nsColor = NSColor(
            srgbRed: b.color.r,
            green: b.color.g,
            blue: b.color.b,
            alpha: b.color.a
        )
        colorWell.color = nsColor
        hexField.stringValue = hexString(from: b.color)
        // Airbrush is the only brush that wants a much larger Size range —
        // it's commonly used for soft fills covering hundreds of pixels.
        // Inking brushes (G-Pen, Marker, Eraser) cap at the smaller scale
        // so the slider stays useful at typical line-art sizes.
        let sizeMax: Double = (b.id == "airbrush") ? 1000 : 80
        rows["size"]?.setRange(min: 1, max: sizeMax)
        rows["size"]?.value = Double(b.radius)
        rows["hardness"]?.value = Double(b.hardness)
        rows["spacing"]?.value = Double(b.spacing)
        rows["opacity"]?.value = Double(b.opacity)
        rows["p2size"]?.value = Double(b.pressureToSizeStrength)
        rows["p2alpha"]?.value = Double(b.pressureToOpacityStrength)
        rows["tiltSize"]?.value = Double(b.tiltSizeInfluence)
        rows["sizeJitter"]?.value = Double(b.sizeJitter)
        rows["alphaJitter"]?.value = Double(b.opacityJitter)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard !refreshing else { return }
        let ns = sender.color.usingColorSpace(.sRGB) ?? sender.color
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ns.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        BrushPalette.shared.updateActive { brush in
            brush.color = ColorRGBA(r: rr, g: gg, b: bb, a: aa)
        }
    }

    @objc private func hexChanged(_ sender: NSTextField) {
        guard !refreshing else { return }
        if let color = parseHexColor(sender.stringValue) {
            BrushPalette.shared.updateActive { $0.color = color }
        } else {
            // Restore the field with the current brush's hex on parse failure.
            sender.stringValue = hexString(from: BrushPalette.shared.activeBrush.color)
        }
    }

    @objc fileprivate func swatchClicked(_ sender: SwatchButton) {
        BrushPalette.shared.updateActive { $0.color = sender.color }
    }
}

private func parseHexColor(_ s: String) -> ColorRGBA? {
    var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6 || hex.count == 3 else { return nil }
    if hex.count == 3 {
        // Expand "abc" → "aabbcc"
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard let value = UInt32(hex, radix: 16) else { return nil }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return ColorRGBA(r: r, g: g, b: b, a: 1.0)
}

private func hexString(from color: ColorRGBA) -> String {
    let r = max(0, min(255, Int((color.r * 255).rounded())))
    let g = max(0, min(255, Int((color.g * 255).rounded())))
    let b = max(0, min(255, Int((color.b * 255).rounded())))
    return String(format: "#%02X%02X%02X", r, g, b)
}

fileprivate final class SwatchButton: NSButton {
    let color: ColorRGBA

    init(color: ColorRGBA) {
        self.color = color
        super.init(frame: .zero)
        title = ""
        bezelStyle = .smallSquare
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = String(format: "#%02X%02X%02X",
                         Int((color.r * 255).rounded()),
                         Int((color.g * 255).rounded()),
                         Int((color.b * 255).rounded()))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class SliderRow: NSStackView {
    private let labelView = NSTextField(labelWithString: "")
    private let valueView = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: String

    var onChange: ((Double) -> Void)?

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            valueView.stringValue = String(format: format, newValue)
        }
    }

    /// Update the slider's range. Used when the active brush changes and a
    /// row should expose a different scale (e.g. Airbrush wants a much
    /// larger Size cap than the inking brushes). Clamps the current value
    /// to the new range so the slider position stays valid.
    func setRange(min: Double, max: Double) {
        slider.minValue = min
        slider.maxValue = max
        if slider.doubleValue < min { slider.doubleValue = min }
        if slider.doubleValue > max { slider.doubleValue = max }
        valueView.stringValue = String(format: format, slider.doubleValue)
    }

    init(label: String, min: Double, max: Double, fmt: String) {
        self.format = fmt
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        labelView.stringValue = label
        labelView.font = NSFont.systemFont(ofSize: 11)
        labelView.textColor = .secondaryLabelColor
        valueView.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueView.alignment = .right
        valueView.textColor = .tertiaryLabelColor
        slider.minValue = min
        slider.maxValue = max
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        labelView.translatesAutoresizingMaskIntoConstraints = false
        valueView.translatesAutoresizingMaskIntoConstraints = false

        addArrangedSubview(labelView)
        addArrangedSubview(slider)
        addArrangedSubview(valueView)
        labelView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        valueView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        valueView.stringValue = String(format: fmt, slider.doubleValue)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged(_ sender: NSSlider) {
        valueView.stringValue = String(format: format, sender.doubleValue)
        onChange?(sender.doubleValue)
    }
}
