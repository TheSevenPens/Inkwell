import AppKit
import Metal
import MetalKit
import simd

private enum StrokeTarget {
    case layer(layerId: UUID)
    case mask(layerId: UUID)
}

private enum SelectionGesture {
    case rectangle(start: CGPoint, current: CGPoint, op: Selection.Op)
    case ellipse(start: CGPoint, current: CGPoint, op: Selection.Op)
    case lasso(points: [CGPoint], op: Selection.Op)
}

final class CanvasView: MTKView {
    private weak var document: Document?
    private let canvas: Canvas
    private var renderer: CanvasRenderer?
    private var stampRenderer: StampRenderer?

    private var currentBrushID: String = ""
    private var tipTexture: (any MTLTexture)?

    private var emitter: StrokeEmitter?
    private var strokeTarget: StrokeTarget?
    private var strokeBeforeLayer = BitmapLayer.TileSnapshot.empty
    private var strokeBeforeMask = LayerMask.TileSnapshot.empty
    private var strokeAffectedCoords: Set<TileCoord> = []

    private var selectionGesture: SelectionGesture?

    private var lastSample: StylusSample?
    private var airbrushTimer: Timer?
    private var antsTimer: Timer?

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
            self?.updateAntsTimer()
        }

        BrushPalette.shared.addObserver { [weak self] in
            self?.brushPaletteChanged()
        }

        canvas.addObserver { [weak self] in
            self?.needsDisplay = true
            self?.updateAntsTimer()
        }

        ToolState.shared.addObserver { [weak self] in
            if let win = self?.window { win.invalidateCursorRects(for: self!) }
            self?.needsDisplay = true
        }

        updateAntsTimer()
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
        if let win = window {
            win.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    private func rebuildTipTextureIfNeeded() {
        let brush = BrushPalette.shared.activeBrush
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

    @objc func fitToWindow(_ sender: Any?) { fitCanvasToView() }

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

    private func canvasPointForEvent(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return viewTransform.windowToCanvas(local)
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

    // MARK: - Mouse / stylus dispatch

    override func mouseDown(with event: NSEvent) {
        if spaceHeld { beginPan(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            beginStroke(at: sampleFor(event: event))
        case .selectRectangle:
            beginSelectionGesture(.rectangle(start: canvasPointForEvent(event),
                                             current: canvasPointForEvent(event),
                                             op: selectionOp(event)))
        case .selectEllipse:
            beginSelectionGesture(.ellipse(start: canvasPointForEvent(event),
                                           current: canvasPointForEvent(event),
                                           op: selectionOp(event)))
        case .selectLasso:
            beginSelectionGesture(.lasso(points: [canvasPointForEvent(event)],
                                         op: selectionOp(event)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning { continuePan(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            let sample = sampleFor(event: event)
            lastSample = sample
            emitter?.continueTo(sample)
        case .selectRectangle, .selectEllipse, .selectLasso:
            updateSelectionGesture(with: canvasPointForEvent(event))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning { endPan(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            let sample = sampleFor(event: event)
            emitter?.end(sample)
            emitter = nil
            stopAirbrushTimer()
            commitUndoIfNeeded()
        case .selectRectangle, .selectEllipse, .selectLasso:
            commitSelectionGesture()
        }
    }

    // MARK: - Brush stroke path

    private func beginStroke(at sample: StylusSample) {
        guard let activeBitmap = canvas.activeBitmapLayer else { return }
        if canvas.editingMask, activeBitmap.mask != nil {
            strokeTarget = .mask(layerId: activeBitmap.id)
        } else {
            strokeTarget = .layer(layerId: activeBitmap.id)
        }
        strokeBeforeLayer = .empty
        strokeBeforeMask = .empty
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
        guard let stampRenderer, let tipTex = tipTexture,
              let strokeTarget else { return }
        let brush = BrushPalette.shared.activeBrush
        let selectionTexture = canvas.selection?.texture ?? canvas.defaultMaskTexture

        let sizePressure = lerp(1.0, brush.pressureToSize.evaluate(sample.pressure),
                                brush.pressureToSizeStrength)
        let alphaPressure = lerp(1.0, brush.pressureToOpacity.evaluate(sample.pressure),
                                 brush.pressureToOpacityStrength)
        let tiltMag = min(1.0, sqrt(sample.tiltX * sample.tiltX + sample.tiltY * sample.tiltY))
        let tiltSizeFactor = 1.0 - brush.tiltSizeInfluence * tiltMag
        let tiltAngle: CGFloat = brush.tiltAngleFollow
            ? atan2(sample.tiltY, sample.tiltX)
            : 0
        let sizeJitter = brush.sizeJitter > 0
            ? 1.0 + CGFloat.random(in: -brush.sizeJitter...brush.sizeJitter)
            : 1.0
        let opacityJitter = brush.opacityJitter > 0
            ? 1.0 - CGFloat.random(in: 0...brush.opacityJitter)
            : 1.0
        let radius = max(0.5, brush.radius * sizePressure * tiltSizeFactor * sizeJitter)
        let alpha = max(0, min(1, brush.opacity * alphaPressure * opacityJitter))

        let halfBox = radius * 1.42
        let bbox = CGRect(
            x: sample.canvasPoint.x - halfBox,
            y: sample.canvasPoint.y - halfBox,
            width: halfBox * 2,
            height: halfBox * 2
        )

        switch strokeTarget {
        case .layer(let layerId):
            guard let layer = canvas.findLayer(layerId) as? BitmapLayer else { return }
            let coords = layer.tilesIntersecting(bbox)
            let newCoords = coords.filter { !strokeAffectedCoords.contains($0) }
            if !newCoords.isEmpty {
                let snap = layer.snapshotTiles(Set(newCoords))
                for (k, v) in snap.presentTiles {
                    strokeBeforeLayer.presentTiles[k] = v
                }
                strokeBeforeLayer.absentTiles.formUnion(snap.absentTiles)
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
            stampRenderer.applyStamp(
                dispatch,
                tipTexture: tipTex,
                selectionTexture: selectionTexture,
                layer: layer
            )

        case .mask(let layerId):
            guard let layer = canvas.findLayer(layerId) as? BitmapLayer,
                  let mask = layer.mask else { return }
            let coords = mask.tilesIntersecting(bbox)
            let newCoords = coords.filter { !strokeAffectedCoords.contains($0) }
            if !newCoords.isEmpty {
                let snap = mask.snapshotTiles(Set(newCoords))
                for (k, v) in snap.presentTiles {
                    strokeBeforeMask.presentTiles[k] = v
                }
                strokeBeforeMask.absentTiles.formUnion(snap.absentTiles)
                strokeAffectedCoords.formUnion(newCoords)
            }
            let c = brush.color.simd
            let luminance = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let dispatch = StampDispatch(
                canvasCenter: sample.canvasPoint,
                radius: radius,
                alpha: Float(alpha),
                angleRadians: Float(tiltAngle),
                color: SIMD4<Float>(luminance, luminance, luminance, 1.0),
                blendMode: .normal
            )
            stampRenderer.applyMaskStamp(
                dispatch,
                tipTexture: tipTex,
                selectionTexture: selectionTexture,
                mask: mask
            )
        }
        needsDisplay = true
    }

    private func commitUndoIfNeeded() {
        defer {
            strokeTarget = nil
            strokeBeforeLayer = .empty
            strokeBeforeMask = .empty
            strokeAffectedCoords = []
        }
        guard let document, let target = strokeTarget,
              !strokeAffectedCoords.isEmpty else { return }
        switch target {
        case .layer(let layerId):
            guard let layer = canvas.findLayer(layerId) as? BitmapLayer else { return }
            let after = layer.snapshotTiles(strokeAffectedCoords)
            document.registerLayerStrokeUndo(layerId: layerId, before: strokeBeforeLayer, after: after)
            document.updateChangeCount(.changeDone)
        case .mask(let layerId):
            guard let layer = canvas.findLayer(layerId) as? BitmapLayer,
                  let mask = layer.mask else { return }
            let after = mask.snapshotTiles(strokeAffectedCoords)
            document.registerMaskStrokeUndo(layerId: layerId, before: strokeBeforeMask, after: after)
            document.updateChangeCount(.changeDone)
        }
    }

    // MARK: - Selection gesture

    private func selectionOp(_ event: NSEvent) -> Selection.Op {
        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let opt = mods.contains(.option)
        if shift && opt { return .intersect }
        if shift { return .add }
        if opt { return .subtract }
        return .replace
    }

    private func beginSelectionGesture(_ gesture: SelectionGesture) {
        selectionGesture = gesture
    }

    private func updateSelectionGesture(with point: CGPoint) {
        guard var g = selectionGesture else { return }
        switch g {
        case .rectangle(let start, _, let op):
            g = .rectangle(start: start, current: point, op: op)
        case .ellipse(let start, _, let op):
            g = .ellipse(start: start, current: point, op: op)
        case .lasso(var points, let op):
            points.append(point)
            g = .lasso(points: points, op: op)
        }
        selectionGesture = g
        // No live preview in Phase 7 Pass 1; commit on mouseUp.
    }

    private func commitSelectionGesture() {
        guard let g = selectionGesture else { return }
        defer { selectionGesture = nil }
        guard let document else { return }
        switch g {
        case .rectangle(let start, let current, let op):
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            guard rect.width >= 1, rect.height >= 1 else { return }
            applySelectionShape(.rectangle(rect: rect), op: op)
        case .ellipse(let start, let current, let op):
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            guard rect.width >= 1, rect.height >= 1 else { return }
            applySelectionShape(.ellipse(rect: rect), op: op)
        case .lasso(let points, let op):
            guard points.count >= 3 else { return }
            let path = CGMutablePath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
            applySelectionShape(.path(path), op: op)
        }
        document.updateChangeCount(.changeDone)
    }

    private enum Shape {
        case rectangle(rect: CGRect)
        case ellipse(rect: CGRect)
        case path(CGPath)
    }

    private func applySelectionShape(_ shape: Shape, op: Selection.Op) {
        let scratch = canvas.selection ?? Selection(
            device: canvas.device,
            canvasWidth: canvas.width,
            canvasHeight: canvas.height
        )
        let bytes: [UInt8]
        switch shape {
        case .rectangle(let rect):
            bytes = scratch.rasterizeRect(rect)
        case .ellipse(let rect):
            bytes = scratch.rasterizeEllipse(in: rect)
        case .path(let path):
            bytes = scratch.rasterizePath(path)
        }
        canvas.applySelection(shape: bytes, op: op)
    }

    // MARK: - Selection menu actions (routed via responder chain)

    @objc override func selectAll(_ sender: Any?) {
        canvas.selectAll()
        document?.updateChangeCount(.changeDone)
    }

    @objc func deselect(_ sender: Any?) {
        canvas.deselect()
        document?.updateChangeCount(.changeDone)
    }

    @objc func invertSelection(_ sender: Any?) {
        canvas.invertSelection()
        document?.updateChangeCount(.changeDone)
    }

    // MARK: - Mouse-moved (cursor + airbrush)

    override func mouseMoved(with event: NSEvent) {
        if ToolState.shared.tool == .brush {
            lastSample = sampleFor(event: event)
        }
    }

    // MARK: - Airbrush

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
        dispatchSample(sample)
    }

    // MARK: - Marching ants animation

    private func updateAntsTimer() {
        if canvas.selection != nil {
            if antsTimer == nil {
                antsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    self?.needsDisplay = true
                }
            }
        } else {
            antsTimer?.invalidate()
            antsTimer = nil
        }
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
            switch ToolState.shared.tool {
            case .brush:
                brushCursor().set()
            case .selectRectangle, .selectEllipse, .selectLasso:
                NSCursor.crosshair.set()
            }
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
