import AppKit
import Metal
import MetalKit
import simd

final class CanvasView: MTKView {
    private weak var document: Document?
    private let canvas: BitmapCanvas
    private var renderer: CanvasRenderer?
    private var brush = Brush()
    private var stamp: CGImage

    private var emitter: StrokeEmitter?
    private var preStrokeSnapshot: Data?

    private var viewTransform = ViewTransform()
    private var hasFitOnce = false

    private var spaceHeld = false
    private var isPanning = false
    private var panStartPoint: NSPoint = .zero
    private var panStartOffset: CGPoint = .zero

    init(document: Document) {
        self.document = document
        self.canvas = document.canvas
        let device = MTLCreateSystemDefaultDevice()!
        let brush = Brush()
        self.brush = brush
        self.stamp = brush.makeStampImage()
        super.init(frame: .zero, device: device)

        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = true
        self.isPaused = false
        self.delegate = self

        do {
            let r = try CanvasRenderer(device: device, viewColorPixelFormat: self.colorPixelFormat)
            r.attach(canvas: canvas)
            self.renderer = r
        } catch {
            NSLog("CanvasRenderer init failed: \(error)")
        }

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
            self?.renderer?.canvasDidChange()
            self?.needsDisplay = true
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

    // MARK: - View transform helpers

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

    private func canvasPointForEvent(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return viewTransform.windowToCanvas(local)
    }

    // MARK: - Mouse / stylus

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {
            beginPan(with: event)
            return
        }
        beginStroke(at: canvasPointForEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            continuePan(with: event)
            return
        }
        continueStroke(to: canvasPointForEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            endPan(with: event)
            return
        }
        endStroke(at: canvasPointForEvent(event))
    }

    private func beginStroke(at point: CGPoint) {
        preStrokeSnapshot = canvas.snapshotPixels()
        let e = StrokeEmitter(brush: brush, stamp: stamp, canvas: canvas)
        e.begin(at: point)
        emitter = e
        markDirty()
    }

    private func continueStroke(to point: CGPoint) {
        emitter?.continueTo(point)
        markDirty()
    }

    private func endStroke(at point: CGPoint) {
        emitter?.end(at: point)
        emitter = nil
        markDirty()
        commitUndoIfNeeded()
    }

    private func commitUndoIfNeeded() {
        guard let document, let before = preStrokeSnapshot else { return }
        let after = canvas.snapshotPixels()
        document.registerStrokeUndo(before: before, after: after)
        document.updateChangeCount(.changeDone)
        preStrokeSnapshot = nil
    }

    private func markDirty() {
        renderer?.canvasDidChange()
        needsDisplay = true
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

extension CanvasView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let renderer else { return }
        let boundsPt = bounds.size
        let drawablePx = view.drawableSize
        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        let matrix = viewTransform.clipTransform(
            viewBoundsPt: boundsPt,
            viewDrawablePx: drawablePx,
            canvasSize: canvasSize
        )
        renderer.render(in: view, transform: matrix)
    }
}
