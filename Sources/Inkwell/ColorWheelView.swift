import AppKit

/// Standard HSV color wheel: a hue ring around the outside, an SV (saturation
/// + value) square in the middle. Click or drag inside either region to pick.
///
/// `setColor(_:)` is the programmatic update path (no callback). `mouseDown` /
/// `mouseDragged` updates from user input *and* fires `onColorChanged`. This
/// asymmetry is deliberate so external observers (e.g. `BrushPalette`) can
/// push the active color back into the wheel without re-triggering.
final class ColorWheelView: NSView {
    /// Fired on user-driven changes only. Programmatic `setColor` updates do
    /// not invoke this.
    var onColorChanged: ((ColorRGBA) -> Void)?

    private var hue: CGFloat = 0       // 0..1
    private var saturation: CGFloat = 1 // 0..1
    private var value: CGFloat = 1     // 0..1

    private enum DragMode { case none, ring, square }
    private var dragMode: DragMode = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }   // standard math coords for trig

    override var intrinsicContentSize: NSSize {
        // Square; concrete size driven by the parent's leading/trailing pins
        // and an aspect-ratio constraint. Hint a sensible minimum so it
        // doesn't collapse to nothing in narrow panes.
        NSSize(width: 80, height: 80)
    }

    // MARK: - Color in / out

    /// Push an external color into the wheel. Updates the indicator
    /// positions; does not invoke `onColorChanged`.
    func setColor(_ color: ColorRGBA) {
        // Convert sRGB → HSV using NSColor in sRGB space for correctness.
        let ns = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Preserve hue when saturation collapses to 0 (grayscale): otherwise
        // dragging value down to 0 and back up resets the user's hue.
        if s > 0.0001 { hue = h }
        saturation = s
        value = v
        needsDisplay = true
    }

    /// Current color in sRGB.
    private var currentColor: ColorRGBA {
        let (r, g, b) = Self.hsvToRGB(h: hue, s: saturation, v: value)
        return ColorRGBA(r: r, g: g, b: b, a: 1)
    }

    // MARK: - Geometry

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private var outerRadius: CGFloat {
        max(0, min(bounds.width, bounds.height) / 2 - 1)
    }

    private var ringThickness: CGFloat {
        let r = outerRadius
        return max(8, min(20, r * 0.18))
    }

    private var innerRadius: CGFloat {
        max(0, outerRadius - ringThickness - 2)  // small gap between ring and SV square
    }

    private var svSquareRect: CGRect {
        let side = innerRadius * sqrt(2) - 6
        return CGRect(
            x: center.x - side / 2,
            y: center.y - side / 2,
            width: max(0, side),
            height: max(0, side)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, outerRadius > 0 else { return }
        drawHueRing(in: ctx)
        drawSVSquare(in: ctx)
        drawHueIndicator(in: ctx)
        drawSVIndicator(in: ctx)
    }

    private func drawHueRing(in ctx: CGContext) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 7-stop sRGB sweep: red → yellow → green → cyan → blue → magenta → red.
        let stops: [CGColor] = [
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor,
            NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1).cgColor,
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor,
            NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1).cgColor,
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor,
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor,
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
        ]
        let locs: [CGFloat] = [0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1]
        guard let gradient = CGGradient(colorsSpace: cs, colors: stops as CFArray, locations: locs) else { return }

        ctx.saveGState()
        let outerRect = CGRect(x: center.x - outerRadius, y: center.y - outerRadius,
                               width: outerRadius * 2, height: outerRadius * 2)
        ctx.addEllipse(in: outerRect)
        ctx.clip()
        // Direct C call: the Swift CGContext overlay doesn't expose a
        // drawConicGradient method on this SDK.
        CGContextDrawConicGradient(ctx, gradient, center, 0)
        ctx.restoreGState()

        // Punch out the inner area so the disc becomes a ring.
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.fillEllipse(in: CGRect(
            x: center.x - innerRadius - 1,
            y: center.y - innerRadius - 1,
            width: (innerRadius + 1) * 2,
            height: (innerRadius + 1) * 2
        ))
        ctx.restoreGState()

        // Subtle outer rim for legibility against varied backgrounds.
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: outerRect)
    }

    private func drawSVSquare(in ctx: CGContext) {
        let rect = svSquareRect
        guard rect.width > 1 else { return }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let (hr, hg, hb) = Self.hsvToRGB(h: hue, s: 1, v: 1)
        let hueColor = NSColor(srgbRed: hr, green: hg, blue: hb, alpha: 1).cgColor

        ctx.saveGState()
        ctx.clip(to: rect)

        // Base: the pure hue at full sat / full value.
        ctx.setFillColor(hueColor)
        ctx.fill(rect)

        // Horizontal: white (sat=0) on the left fading to clear (so the hue shows on the right).
        if let satGrad = CGGradient(colorsSpace: cs, colors: [
            NSColor.white.withAlphaComponent(1).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                satGrad,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }

        // Vertical: clear at the top (value=1) fading to black at the bottom (value=0).
        if let valGrad = CGGradient(colorsSpace: cs, colors: [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(1).cgColor
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                valGrad,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.minX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)
    }

    private func drawHueIndicator(in ctx: CGContext) {
        let midR = (outerRadius + innerRadius) / 2
        let angle = hue * 2 * .pi
        let x = center.x + cos(angle) * midR
        let y = center.y + sin(angle) * midR
        let r: CGFloat = max(3, ringThickness * 0.45)
        drawHandle(in: ctx, at: CGPoint(x: x, y: y), radius: r)
    }

    private func drawSVIndicator(in ctx: CGContext) {
        let rect = svSquareRect
        guard rect.width > 1 else { return }
        let x = rect.minX + saturation * rect.width
        let y = rect.minY + value * rect.height  // value=1 at the top (high y, non-flipped)
        drawHandle(in: ctx, at: CGPoint(x: x, y: y), radius: 5)
    }

    private func drawHandle(in ctx: CGContext, at p: CGPoint, radius r: CGFloat) {
        let outer = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let inner = outer.insetBy(dx: 1, dy: 1)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokeEllipse(in: inner)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.strokeEllipse(in: outer)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hitRing(p) {
            dragMode = .ring
            updateHue(from: p)
        } else if svSquareRect.contains(p) {
            dragMode = .square
            updateSV(from: p)
        } else {
            dragMode = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .ring:   updateHue(from: p)
        case .square: updateSV(from: p)
        case .none:   break
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
    }

    private func hitRing(_ p: CGPoint) -> Bool {
        let d = hypot(p.x - center.x, p.y - center.y)
        return d >= innerRadius && d <= outerRadius
    }

    private func updateHue(from p: CGPoint) {
        var angle = atan2(p.y - center.y, p.x - center.x)
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        needsDisplay = true
        onColorChanged?(currentColor)
    }

    private func updateSV(from p: CGPoint) {
        let rect = svSquareRect
        guard rect.width > 0, rect.height > 0 else { return }
        let s = max(0, min(1, (p.x - rect.minX) / rect.width))
        let v = max(0, min(1, (p.y - rect.minY) / rect.height))
        saturation = s
        value = v
        needsDisplay = true
        onColorChanged?(currentColor)
    }

    // MARK: - HSV → RGB (sRGB)

    private static func hsvToRGB(h: CGFloat, s: CGFloat, v: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = floor(hh)
        let f = hh - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0:  return (v, t, p)
        case 1:  return (q, v, p)
        case 2:  return (p, v, t)
        case 3:  return (p, q, v)
        case 4:  return (t, p, v)
        default: return (v, p, q)
        }
    }
}
