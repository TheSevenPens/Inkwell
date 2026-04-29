import AppKit

/// Right-sidebar inspector: live editing of the active brush's settings.
final class BrushInspectorView: NSView {
    private var stack: NSStackView!
    private var nameLabel: NSTextField!
    private var rows: [String: SliderRow] = [:]
    private var colorWell: NSColorWell!
    private var refreshing = false

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
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let title = NSTextField(labelWithString: "Brush Settings")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(nameLabel)

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
        colorRow.addArrangedSubview(colorLabel)
        colorRow.addArrangedSubview(colorWell)
        stack.addArrangedSubview(colorRow)

        addSliderRow(key: "size", label: "Size", min: 1, max: 80, fmt: "%.1f")
        addSliderRow(key: "hardness", label: "Hardness", min: 0, max: 1, fmt: "%.2f")
        addSliderRow(key: "spacing", label: "Spacing", min: 0.02, max: 0.6, fmt: "%.2f")
        addSliderRow(key: "opacity", label: "Opacity", min: 0, max: 1, fmt: "%.2f")
        stack.addArrangedSubview(thinRule())
        addSliderRow(key: "p2size", label: "Press → Size", min: 0, max: 1, fmt: "%.2f")
        addSliderRow(key: "p2alpha", label: "Press → Opacity", min: 0, max: 1, fmt: "%.2f")
        stack.addArrangedSubview(thinRule())
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
        stack.addArrangedSubview(row)
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
