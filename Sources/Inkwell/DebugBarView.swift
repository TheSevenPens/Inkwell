import AppKit

/// Diagnostic toolbar showing the latest stylus event's data and the moving
/// average of tablet sample rate. Toggled via Debug → Show Debug Toolbar.
final class DebugBarView: NSView {
    private let positionLabel = makeLabel()
    private let pressureLabel = makeLabel()
    private let tiltLabel = makeLabel()
    private let azimuthLabel = makeLabel()
    private let altitudeLabel = makeLabel()
    private let rateLabel = makeLabel()
    private let sourceLabel = makeLabel()

    /// Closure provided by the host to fetch a fresh snapshot on every refresh tick.
    var snapshotProvider: (() -> CanvasView.DebugSnapshot)?

    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(deviceWhite: 0.10, alpha: 1.0).cgColor

        for label in [sourceLabel, positionLabel, pressureLabel, tiltLabel, azimuthLabel, altitudeLabel, rateLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor(deviceWhite: 0.85, alpha: 1.0)
        }
        rateLabel.textColor = NSColor.systemYellow

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(sourceLabel)
        stack.addArrangedSubview(positionLabel)
        stack.addArrangedSubview(pressureLabel)
        stack.addArrangedSubview(tiltLabel)
        stack.addArrangedSubview(azimuthLabel)
        stack.addArrangedSubview(altitudeLabel)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(rateLabel)

        // Bottom-edge separator
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(deviceWhite: 0.30, alpha: 1.0).cgColor
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])

        applyEmpty()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        guard let snap = snapshotProvider?() else { applyEmpty(); return }
        sourceLabel.stringValue = snap.lastEventSource.rawValue
        if let p = snap.lastEventCanvasPos {
            positionLabel.stringValue = String(format: "X: %7.1f  Y: %7.1f", p.x, p.y)
        } else {
            positionLabel.stringValue = "X: ——————  Y: ——————"
        }
        pressureLabel.stringValue = String(format: "P: %.3f", snap.lastEventPressure)
        tiltLabel.stringValue = String(format: "Tilt: x=%+.2f y=%+.2f", snap.lastEventTiltX, snap.lastEventTiltY)
        azimuthLabel.stringValue = String(format: "Az: %5.1f°", snap.lastEventAzimuthDegrees)
        altitudeLabel.stringValue = String(format: "Alt: %4.1f°", snap.lastEventAltitudeDegrees)
        rateLabel.stringValue = "\(snap.tabletReportsPerSecond) Hz"
    }

    private func applyEmpty() {
        sourceLabel.stringValue = "—"
        positionLabel.stringValue = "X: ——————  Y: ——————"
        pressureLabel.stringValue = "P: ——"
        tiltLabel.stringValue = "Tilt: x=——— y=———"
        azimuthLabel.stringValue = "Az: ——°"
        altitudeLabel.stringValue = "Alt: ——°"
        rateLabel.stringValue = "0 Hz"
    }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
