import AppKit
import Metal
import MetalKit
import simd

final class CanvasView: MTKView {
    private weak var document: Document?
    private let canvas: BitmapCanvas
    private var renderer: CanvasRenderer?
    private var stampRenderer: StampRenderer?

    private var currentBrushID: String = ""
    private var tipTexture: (any MTLTexture)?

    private var emitter: StrokeEmitter?
    private var strokeBeforeSnapshot = BitmapCanvas.TileSnapshot.empty
    private var strokeAffectedCoords: Set<TileCoord> = []

    private var lastSample: StylusSample?
    private var airbrushTimer: Timer?

    private var viewTransform = ViewTransform()
    private var hasFitOnce = false

    private var spaceHeld = false
    private var isPanning = false
    private var panStartPoint: NSPoint = .zero
    private var panStartOffset: CGPoint = .zero

    init(document: Document) {
        self.document = document
        self.canvas = document.canvas
        let device = canvas.device
        super.init(frame: .zero, device: device)

        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = true
        self.isPaused = false
        self.delegate = self

        do {
            let r = try CanvasRenderer(
                device: device,
                commandQueue: canvas.commandQueue,
                viewColorPixelFormat: self.colorPixelFormat
            )
            r.attach(canvas: canvas)
            self.renderer = r
        } catch {
            NSLog("CanvasRenderer init failed: \(error)")
        }

        do {
            self.stampRenderer = try StampRenderer(
                device: device,
                commandQueue: canvas.commandQueue
            )
        } catch {
            NSLog("StampRenderer init failed: \(error)")
        }

        rebuildTipTextureIfNeeded()

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        document.onCanvasChanged = { [weak self] in
            self?.needsDisplay = true
        }

        BrushPalette.shared.addObserver { [weak self] in
            self?.brushPaletteChanged()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        if !hasFitOnce, bounds.width > 8, bounds.height > 8 {
            fitCanvasToView()
            hasFitOnce = true
        }
    }

    // MARK: - Brush palette

    private func brushPaletteChanged() {
        rebuildTipTextureIfNeeded()
        // Cursor reflects the new brush size
        if let win = window {
            win.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    private func rebuildTipTextureIfNeeded() {
        let brush = BrushPalette.shared.activeBrush
        // Generate one tip per (id + hardness). Hardness is the visual variable that
        // changes the mask; size is applied at draw time.
        let key = "\(brush.id)|\(Int(brush.hardness * 1000))"
        if key != currentBrushID {
            tipTexture = brush.makeTipTexture(device: canvas.device)
            currentBrushID = key
        }
    }

    // MARK: - View transform

    private func fitCanvasToView() {
        guard bounds.width > 8, bounds.height > 8 else { return }
        let cw = CGFloat(canvas.width)
        let ch = CGFloat(canvas.height)
        let pad: CGFloat = 24
        let sx = (bounds.width - pad * 2) / cw
        let sy = (bounds.height - pad * 2) / ch
        let s = max(ViewTransform.minScale, min(sx, sy, 8.0))
        viewTransform.scale = s
        let cwPt = cw * s
        let chPt = ch * s
        viewTransform.offset = CGPoint(
            x: (bounds.width - cwPt) / 2.0,
            y: (bounds.height - chPt) / 2.0
        )
        needsDisplay = true
    }

    @objc func fitToWindow(_ sender: Any?) {
        fitCanvasToView()
    }

    @objc func actualSize(_ sender: Any?) {
        let cw = CGFloat(canvas.width)
        let ch = CGFloat(canvas.height)
        viewTransform.scale = 1.0
        viewTransform.offset = CGPoint(
            x: (bounds.width - cw) / 2.0,
            y: (bounds.height - ch) / 2.0
        )
        needsDisplay = true
    }

    // MARK: - Coordinate mapping

    private func sampleFor(event: NSEvent) -> StylusSample {
        let local = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewTransform.windowToCanvas(local)
        let isStylus = (event.subtype == .tabletPoint)
        return StylusSample(
            canvasPoint: canvasPoint,
            pressure: isStylus ? CGFloat(event.pressure) : 1.0,
            tiltX: isStylus ? CGFloat(event.tilt.x) : 0,
            tiltY: isStylus ? CGFloat(event.tilt.y) : 0
        )
    }

    private func visibleCanvasRect() -> CGRect {
        let w = bounds.width
        let h = bounds.height
        let p00 = viewTransform.windowToCanvas(CGPoint(x: 0, y: 0))
        let p10 = viewTransform.windowToCanvas(CGPoint(x: w, y: 0))
        let p01 = viewTransform.windowToCanvas(CGPoint(x: 0, y: h))
        let p11 = viewTransform.windowToCanvas(CGPoint(x: w, y: h))
        let minX = min(p00.x, p10.x, p01.x, p11.x)
        let maxX = max(p00.x, p10.x, p01.x, p11.x)
        let minY = min(p00.y, p10.y, p01.y, p11.y)
        let maxY = max(p00.y, p10.y, p01.y, p11.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Mouse / stylus

    override func mouseDown(with event: NSEvent) {
        if spaceHeld { beginPan(with: event); return }
        beginStroke(at: sampleFor(event: event))
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning { continuePan(with: event); return }
        let sample = sampleFor(event: event)
        lastSample = sample
        emitter?.continueTo(sample)
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning { endPan(with: event); return }
        let sample = sampleFor(event: event)
        emitter?.end(sample)
        emitter = nil
        stopAirbrushTimer()
        commitUndoIfNeeded()
    }

    private func beginStroke(at sample: StylusSample) {
        strokeBeforeSnapshot = .empty
        strokeAffectedCoords = []
        rebuildTipTextureIfNeeded()
        lastSample = sample
        let brush = BrushPalette.shared.activeBrush
        let e = StrokeEmitter(brush: brush) { [weak self] s in
            self?.dispatchSample(s)
        }
        e.begin(sample)
        emitter = e
        startAirbrushTimerIfNeeded()
    }

    private func dispatchSample(_ sample: StylusSample) {
        guard let stampRenderer, let tipTex = tipTexture else { return }
        let brush = BrushPalette.shared.activeBrush

        // Pressure response.
        let sizePressure = lerp(1.0, brush.pressureToSize.evaluate(sample.pressure),
                                brush.pressureToSizeStrength)
        let alphaPressure = lerp(1.0, brush.pressureToOpacity.evaluate(sample.pressure),
                                 brush.pressureToOpacityStrength)

        // Tilt response.
        let tiltMag = min(1.0, sqrt(sample.tiltX * sample.tiltX + sample.tiltY * sample.tiltY))
        let tiltSizeFactor = 1.0 - brush.tiltSizeInfluence * tiltMag
        let tiltAngle: CGFloat = brush.tiltAngleFollow
            ? atan2(sample.tiltY, sample.tiltX)
            : 0

        // Jitter.
        let sizeJitter = brush.sizeJitter > 0
            ? 1.0 + CGFloat.random(in: -brush.sizeJitter...brush.sizeJitter)
            : 1.0
        let opacityJitter = brush.opacityJitter > 0
            ? 1.0 - CGFloat.random(in: 0...brush.opacityJitter)
            : 1.0

        let radius = max(0.5, brush.radius * sizePressure * tiltSizeFactor * sizeJitter)
        let alpha = max(0, min(1, brush.opacity * alphaPressure * opacityJitter))

        // Track dirty tiles.
        let halfBox = radius * 1.42
        let bbox = CGRect(
            x: sample.canvasPoint.x - halfBox,
            y: sample.canvasPoint.y - halfBox,
            width: halfBox * 2,
            height: halfBox * 2
        )
        let coords = canvas.tilesIntersecting(bbox)
        let newCoords = coords.filter { !strokeAffectedCoords.contains($0) }
        if !newCoords.isEmpty {
            let snap = canvas.snapshotTiles(Set(newCoords))
            for (k, v) in snap.presentTiles {
                strokeBeforeSnapshot.presentTiles[k] = v
            }
            strokeBeforeSnapshot.absentTiles.formUnion(snap.absentTiles)
            strokeAffectedCoords.formUnion(newCoords)
        }

        let dispatch = StampDispatch(
            canvasCenter: sample.canvasPoint,
            radius: radius,
            alpha: Float(alpha),
            angleRadians: Float(tiltAngle),
            color: brush.color.simd,
            blendMode: brush.blendMode
        )
        stampRenderer.applyStamp(dispatch, tipTexture: tipTex, canvas: canvas)
        needsDisplay = true
    }

    private func commitUndoIfNeeded() {
        guard let document, !strokeAffectedCoords.isEmpty else { return }
        let after = canvas.snapshotTiles(strokeAffectedCoords)
        document.registerStrokeUndo(before: strokeBeforeSnapshot, after: after)
        document.updateChangeCount(.changeDone)
        strokeBeforeSnapshot = .empty
        strokeAffectedCoords = []
    }

    // MARK: - Mouse-moved tracking (for cursor + airbrush)

    override func mouseMoved(with event: NSEvent) {
        // Track even when not down — airbrush may need it once we start.
        lastSample = sampleFor(event: event)
    }

    // MARK: - Airbrush continuous emission

    private func startAirbrushTimerIfNeeded() {
        let brush = BrushPalette.shared.activeBrush
        guard brush.emissionHz > 0 else { return }
        let interval = 1.0 / Double(brush.emissionHz)
        airbrushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.airbrushTick()
        }
    }

    private func stopAirbrushTimer() {
        airbrushTimer?.invalidate()
        airbrushTimer = nil
    }

    private func airbrushTick() {
        guard let sample = lastSample, emitter != nil else { return }
        // Bypass the spacing emitter and emit directly at the cursor position.
        dispatchSample(sample)
    }

    // MARK: - Pan

    private func beginPan(with event: NSEvent) {
        isPanning = true
        panStartPoint = convert(event.locationInWindow, from: nil)
        panStartOffset = viewTransform.offset
        NSCursor.closedHand.set()
    }

    private func continuePan(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        viewTransform.offset = CGPoint(
            x: panStartOffset.x + (p.x - panStartPoint.x),
            y: panStartOffset.y + (p.y - panStartPoint.y)
        )
        needsDisplay = true
    }

    private func endPan(with event: NSEvent) {
        isPanning = false
        cursorUpdate(with: event)
    }

    // MARK: - Scroll & zoom

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor: CGFloat = 1.0 + event.scrollingDeltaY * 0.01
            viewTransform.zoom(by: factor, at: p)
        } else {
            viewTransform.offset.x += event.scrollingDeltaX
            viewTransform.offset.y += event.scrollingDeltaY
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let factor: CGFloat = 1.0 + event.magnification
        viewTransform.zoom(by: factor, at: p)
        needsDisplay = true
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", !event.isARepeat {
            spaceHeld = true
            cursorUpdate(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            spaceHeld = false
            cursorUpdate(with: event)
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - Cursor

    override func cursorUpdate(with event: NSEvent) {
        if isPanning {
            NSCursor.closedHand.set()
        } else if spaceHeld {
            NSCursor.openHand.set()
        } else {
            brushCursor().set()
        }
    }

    private func brushCursor() -> NSCursor {
        let brush = BrushPalette.shared.activeBrush
        let displayRadius = max(2.0, brush.radius * viewTransform.scale)
        let edge = ceil(displayRadius * 2 + 4)
        let imageSize = NSSize(width: edge, height: edge)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.black.setStroke()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            outer.lineWidth = 1.0
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            inner.lineWidth = 1.0
            inner.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: edge / 2, y: edge / 2))
    }
}

// MARK: - Helpers

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * max(0, min(1, t))
}

extension CanvasView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let renderer else { return }
        let boundsPt = bounds.size
        let drawablePx = view.drawableSize
        let matrix = viewTransform.clipTransform(
            viewBoundsPt: boundsPt,
            viewDrawablePx: drawablePx
        )
        renderer.render(
            in: view,
            viewTransform: matrix,
            visibleCanvasRect: visibleCanvasRect()
        )
    }
}
