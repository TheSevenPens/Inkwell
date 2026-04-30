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
    private var strokeForcesErase: Bool = false
    private var strokeBeforeLayer = BitmapLayer.TileSnapshot.empty
    private var strokeBeforeMask = LayerMask.TileSnapshot.empty
    private var strokeAffectedCoords: Set<TileCoord> = []

    private var selectionGesture: SelectionGesture?
    private var preGestureSelectionBytes: [UInt8]?

    private var lastSample: StylusSample?
    private var lastCursorWindow: CGPoint?
    private var airbrushTimer: Timer?
    private var antsTimer: Timer?

    // Debug telemetry — populated from every input event the canvas sees.
    private var debugLastSource: DebugSnapshot.Source = .none
    private var debugLastCanvasPos: CGPoint?
    private var debugLastPressure: CGFloat = 0
    private var debugLastTiltX: CGFloat = 0
    private var debugLastTiltY: CGFloat = 0
    /// Sliding window of timestamps of the last 1 s of tablet-subtype events.
    private var debugTabletTimestamps: [TimeInterval] = []

    private var viewTransform = ViewTransform()
    private var hasFitOnce = false

    private var spaceHeld = false
    private var rHeld = false
    private var isPanning = false
    private var isRotateDragging = false
    private var panStartPoint: NSPoint = .zero
    private var panStartOffset: CGPoint = .zero
    private var rotateDragStartMouseAngle: CGFloat = 0
    private var rotateDragBaseRotation: CGFloat = 0

    /// Set by DocumentWindowController; called when the user presses Tab.
    var onTogglePanels: (() -> Void)?

    /// Set by DocumentWindowController; called whenever the values shown in the
    /// status bar might have changed (zoom, cursor position, doc size).
    var onStatusChanged: ((StatusSnapshot) -> Void)?

    struct StatusSnapshot {
        /// Current zoom as a percentage, e.g. 100 for 1:1.
        var zoomPercent: Int
        /// Cursor position in canvas-pixel coords, or nil if the cursor is outside the canvas region.
        var canvasPosition: CGPoint?
        /// Document dimensions in canvas pixels.
        var documentSize: (width: Int, height: Int)
        /// View rotation in degrees (CCW positive). 0 if no rotation applied.
        var rotationDegrees: Int
    }

    /// Snapshot of the latest input event for the debug toolbar. Updated on
    /// every mouse / tablet event the canvas sees.
    struct DebugSnapshot {
        enum Source: String {
            case stylus = "Stylus"
            case mouse = "Mouse"
            case none = "—"
        }
        var lastEventSource: Source
        var lastEventCanvasPos: CGPoint?
        var lastEventPressure: CGFloat
        var lastEventTiltX: CGFloat
        var lastEventTiltY: CGFloat
        var lastEventAzimuthDegrees: CGFloat
        var lastEventAltitudeDegrees: CGFloat
        /// Number of tablet (`subtype == .tabletPoint`) events received in the last 1 s.
        var tabletReportsPerSecond: Int
    }

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
            if let self, let win = self.window {
                win.invalidateCursorRects(for: self)
            }
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
        viewTransform.rotation = 0
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
        viewTransform.rotation = 0
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

    // MARK: - Debug telemetry

    /// Capture stylus / mouse parameters from any input event for the debug
    /// toolbar. Counts tablet-subtype events over a 1 s sliding window.
    private func recordEventForDebug(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        debugLastCanvasPos = viewTransform.windowToCanvas(local)
        debugLastPressure = CGFloat(event.pressure)
        let isTabletPoint = (event.type == .tabletPoint || event.subtype == .tabletPoint)
        if isTabletPoint {
            debugLastSource = .stylus
            debugLastTiltX = CGFloat(event.tilt.x)
            debugLastTiltY = CGFloat(event.tilt.y)
            let now = Date().timeIntervalSinceReferenceDate
            debugTabletTimestamps.append(now)
            let cutoff = now - 1.0
            while let first = debugTabletTimestamps.first, first < cutoff {
                debugTabletTimestamps.removeFirst()
            }
        } else {
            debugLastSource = .mouse
            debugLastTiltX = 0
            debugLastTiltY = 0
        }
    }

    /// Compute a fresh debug snapshot for the toolbar. Cheap; called at ~10 Hz
    /// by `DebugBarView`'s refresh timer.
    func currentDebugSnapshot() -> DebugSnapshot {
        let tx = debugLastTiltX
        let ty = debugLastTiltY
        let azimuthRad = atan2(ty, tx)
        var azimuthDeg = azimuthRad * 180.0 / .pi
        if azimuthDeg < 0 { azimuthDeg += 360 }
        let mag = min(1.0, hypot(tx, ty))
        // Approximate: tilt magnitude ≈ sin(angle from vertical).
        let altitudeDeg = 90.0 - asin(mag) * 180.0 / .pi
        // Trim stale timestamps before reading the count.
        let now = Date().timeIntervalSinceReferenceDate
        let cutoff = now - 1.0
        while let first = debugTabletTimestamps.first, first < cutoff {
            debugTabletTimestamps.removeFirst()
        }
        return DebugSnapshot(
            lastEventSource: debugLastSource,
            lastEventCanvasPos: debugLastCanvasPos,
            lastEventPressure: debugLastPressure,
            lastEventTiltX: tx,
            lastEventTiltY: ty,
            lastEventAzimuthDegrees: azimuthDeg,
            lastEventAltitudeDegrees: altitudeDeg,
            tabletReportsPerSecond: debugTabletTimestamps.count
        )
    }

    /// High-frequency tablet sample event. macOS may deliver these alongside
    /// (or interleaved with) mouseDragged when mouse coalescing is disabled.
    /// Tracking them here ensures the debug rate counter sees every report,
    /// and the painting path can use them to fill in between mouseDragged events.
    override func tabletPoint(with event: NSEvent) {
        recordEventForDebug(event)
        // If a stroke is in flight, feed this sample to the emitter so we don't
        // lose intermediate tablet reports between mouseDragged events.
        if let emitter = emitter {
            let sample = sampleFor(event: event)
            lastSample = sample
            emitter.continueTo(sample)
        }
    }

    private func publishStatus(cursorWindow: CGPoint?) {
        let zoomPct = Int((viewTransform.scale * 100.0).rounded())
        let degrees = Int((viewTransform.rotation * 180.0 / .pi).rounded())
        let normalizedDegrees = ((degrees % 360) + 360) % 360
        var canvasPos: CGPoint? = nil
        if let cw = cursorWindow {
            let p = viewTransform.windowToCanvas(cw)
            if p.x >= 0, p.x < CGFloat(canvas.width), p.y >= 0, p.y < CGFloat(canvas.height) {
                canvasPos = p
            }
        }
        onStatusChanged?(StatusSnapshot(
            zoomPercent: zoomPct,
            canvasPosition: canvasPos,
            documentSize: (canvas.width, canvas.height),
            rotationDegrees: normalizedDegrees
        ))
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

    // MARK: - Eyedropper (Cmd-modifier sample)

    private func sampleColorAtCanvasPoint(_ canvasPoint: CGPoint) -> ColorRGBA? {
        guard let layer = canvas.activeBitmapLayer else { return nil }
        let cx = Int(canvasPoint.x.rounded())
        let cy = Int(canvasPoint.y.rounded())
        guard cx >= 0, cx < canvas.width, cy >= 0, cy < canvas.height else { return nil }
        let tx = cx / Canvas.tileSize
        let ty = cy / Canvas.tileSize
        guard let tex = layer.tile(at: TileCoord(x: tx, y: ty)) else { return nil }
        let pxLocalX = cx % Canvas.tileSize
        let pxLocalY = cy % Canvas.tileSize
        // Tile data is top-down; canvas Y `cy` lives at row `tileSize - 1 - pxLocalY`.
        let row = Canvas.tileSize - 1 - pxLocalY
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBufferPointer { buf in
            tex.getBytes(
                buf.baseAddress!,
                bytesPerRow: 4,
                from: MTLRegionMake2D(pxLocalX, row, 1, 1),
                mipmapLevel: 0
            )
        }
        let a = CGFloat(pixel[3]) / 255.0
        if a < 0.001 { return nil }
        // Un-premultiply for color picker semantics.
        let r = min(1.0, CGFloat(pixel[0]) / 255.0 / a)
        let g = min(1.0, CGFloat(pixel[1]) / 255.0 / a)
        let b = min(1.0, CGFloat(pixel[2]) / 255.0 / a)
        return ColorRGBA(r: r, g: g, b: b, a: 1.0)
    }

    // MARK: - Mouse / stylus dispatch

    override func mouseDown(with event: NSEvent) {
        recordEventForDebug(event)
        if spaceHeld { beginPan(with: event); return }
        if rHeld { beginRotateDrag(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            if event.modifierFlags.contains(.command) {
                // Cmd-click (without shift/option being a select-modifier conflict): eyedropper.
                let p = canvasPointForEvent(event)
                if let color = sampleColorAtCanvasPoint(p) {
                    BrushPalette.shared.updateActive { $0.color = color }
                }
                return
            }
            let optionEraser = event.modifierFlags.contains(.option)
            beginStroke(at: sampleFor(event: event), forceErase: optionEraser)
        case .hand:
            beginPan(with: event)
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
        recordEventForDebug(event)
        if isPanning { continuePan(with: event); return }
        if isRotateDragging { continueRotateDrag(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            let sample = sampleFor(event: event)
            lastSample = sample
            emitter?.continueTo(sample)
        case .hand:
            continuePan(with: event)
        case .selectRectangle, .selectEllipse, .selectLasso:
            updateSelectionGesture(with: canvasPointForEvent(event))
        }
    }

    override func mouseUp(with event: NSEvent) {
        recordEventForDebug(event)
        if isPanning { endPan(with: event); return }
        if isRotateDragging { endRotateDrag(with: event); return }
        switch ToolState.shared.tool {
        case .brush:
            let sample = sampleFor(event: event)
            emitter?.end(sample)
            emitter = nil
            stopAirbrushTimer()
            commitUndoIfNeeded()
        case .hand:
            endPan(with: event)
        case .selectRectangle, .selectEllipse, .selectLasso:
            updateSelectionGesture(with: canvasPointForEvent(event))
            commitSelectionGesture()
        }
    }

    // MARK: - Brush stroke path

    private func beginStroke(at sample: StylusSample, forceErase: Bool) {
        guard let activeBitmap = canvas.activeBitmapLayer else { return }
        if canvas.editingMask, activeBitmap.mask != nil {
            strokeTarget = .mask(layerId: activeBitmap.id)
        } else {
            strokeTarget = .layer(layerId: activeBitmap.id)
        }
        strokeForcesErase = forceErase
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
            let blendMode: BrushBlendMode = strokeForcesErase ? .erase : brush.blendMode
            let dispatch = StampDispatch(
                canvasCenter: sample.canvasPoint,
                radius: radius,
                alpha: Float(alpha),
                angleRadians: Float(tiltAngle),
                color: brush.color.simd,
                blendMode: blendMode
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
            strokeForcesErase = false
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
        preGestureSelectionBytes = canvas.selection?.bytes
            ?? [UInt8](repeating: 0, count: canvas.width * canvas.height)
        renderSelectionPreview()
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
        renderSelectionPreview()
    }

    private func commitSelectionGesture() {
        guard selectionGesture != nil else { return }
        defer {
            selectionGesture = nil
            preGestureSelectionBytes = nil
        }
        document?.updateChangeCount(.changeDone)
    }

    private func renderSelectionPreview() {
        guard let g = selectionGesture, let baseline = preGestureSelectionBytes else { return }
        let scratch = canvas.selection ?? Selection(
            device: canvas.device,
            canvasWidth: canvas.width,
            canvasHeight: canvas.height
        )
        let shapeBytes: [UInt8]?
        let op: Selection.Op
        switch g {
        case .rectangle(let start, let current, let theOp):
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            shapeBytes = (rect.width >= 1 && rect.height >= 1) ? scratch.rasterizeRect(rect) : nil
            op = theOp
        case .ellipse(let start, let current, let theOp):
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            shapeBytes = (rect.width >= 1 && rect.height >= 1) ? scratch.rasterizeEllipse(in: rect) : nil
            op = theOp
        case .lasso(let points, let theOp):
            if points.count >= 2 {
                let path = CGMutablePath()
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                shapeBytes = scratch.rasterizePath(path)
            } else {
                shapeBytes = nil
            }
            op = theOp
        }

        let combined: [UInt8]
        if let shape = shapeBytes {
            combined = combine(baseline: baseline, shape: shape, op: op)
        } else {
            combined = baseline
        }
        canvas.replaceSelectionBytes(combined)
    }

    private func combine(baseline: [UInt8], shape: [UInt8], op: Selection.Op) -> [UInt8] {
        precondition(baseline.count == shape.count)
        var out = [UInt8](repeating: 0, count: baseline.count)
        switch op {
        case .replace:
            return shape
        case .add:
            for i in 0..<out.count { out[i] = max(baseline[i], shape[i]) }
        case .subtract:
            for i in 0..<out.count {
                let s = Int(shape[i])
                let c = Int(baseline[i])
                out[i] = UInt8(max(0, c - s))
            }
        case .intersect:
            for i in 0..<out.count {
                let a = Int(baseline[i])
                let b = Int(shape[i])
                out[i] = UInt8((a * b + 127) / 255)
            }
        }
        return out
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

    // MARK: - Mouse-moved / entered / exited

    override func mouseMoved(with event: NSEvent) {
        recordEventForDebug(event)
        if ToolState.shared.tool == .brush {
            lastSample = sampleFor(event: event)
        }
        lastCursorWindow = convert(event.locationInWindow, from: nil)
        publishStatus(cursorWindow: lastCursorWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        lastCursorWindow = convert(event.locationInWindow, from: nil)
        publishStatus(cursorWindow: lastCursorWindow)
    }

    override func mouseExited(with event: NSEvent) {
        lastCursorWindow = nil
        publishStatus(cursorWindow: nil)
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

    // MARK: - Rotate (R + drag)

    private func beginRotateDrag(with event: NSEvent) {
        isRotateDragging = true
        let p = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        rotateDragStartMouseAngle = atan2(p.y - center.y, p.x - center.x)
        rotateDragBaseRotation = viewTransform.rotation
        NSCursor.crosshair.set()
    }

    private func continueRotateDrag(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let cur = atan2(p.y - center.y, p.x - center.x)
        var newRotation = rotateDragBaseRotation + (cur - rotateDragStartMouseAngle)
        if event.modifierFlags.contains(.shift) {
            let step: CGFloat = 15.0 * .pi / 180.0
            newRotation = (newRotation / step).rounded() * step
        }
        viewTransform.setRotation(newRotation, anchor: center)
        needsDisplay = true
    }

    private func endRotateDrag(with event: NSEvent) {
        isRotateDragging = false
        cursorUpdate(with: event)
    }

    // MARK: - Trackpad rotate gesture

    override func rotate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let radiansDelta = CGFloat(event.rotation) * .pi / 180.0
        viewTransform.rotate(by: radiansDelta, at: p)
        needsDisplay = true
    }

    // MARK: - Scroll & zoom

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // hasPreciseScrollingDeltas is true for trackpads / Magic Mouse continuous
        // scrolling; false for traditional mouse wheels with discrete notches.
        if event.hasPreciseScrollingDeltas {
            // Trackpad: pan by default, zoom with Cmd+scroll (cursor-anchored).
            if event.modifierFlags.contains(.command) {
                let factor: CGFloat = 1.0 + event.scrollingDeltaY * 0.01
                viewTransform.zoom(by: factor, at: p)
            } else {
                viewTransform.offset.x += event.scrollingDeltaX
                viewTransform.offset.y += event.scrollingDeltaY
            }
        } else {
            // Mouse wheel: zoom by default (cursor-anchored). Each notch ≈ 10%.
            let factor: CGFloat = 1.0 + event.scrollingDeltaY * 0.10
            viewTransform.zoom(by: factor, at: p)
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
        let chars = event.charactersIgnoringModifiers ?? ""
        // Backspace (keyCode 51) and Forward Delete (keyCode 117) → Edit → Clear.
        if event.keyCode == 51 || event.keyCode == 117 {
            document?.clearAction(self)
            return
        }
        if chars == " ", !event.isARepeat {
            spaceHeld = true
            cursorUpdate(with: event)
            return
        }
        if (chars == "r" || chars == "R"), !event.isARepeat {
            if event.modifierFlags.contains(.shift) {
                // Shift+R: reset rotation to zero around view center.
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                viewTransform.setRotation(0, anchor: center)
                needsDisplay = true
                return
            }
            rHeld = true
            cursorUpdate(with: event)
            return
        }
        if chars == "\t", !event.isARepeat {
            onTogglePanels?()
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == " " {
            spaceHeld = false
            cursorUpdate(with: event)
            return
        }
        if chars == "r" || chars == "R" {
            rHeld = false
            cursorUpdate(with: event)
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - Cursor

    override func cursorUpdate(with event: NSEvent) {
        if isPanning {
            NSCursor.closedHand.set()
        } else if isRotateDragging {
            NSCursor.crosshair.set()
        } else if spaceHeld {
            NSCursor.openHand.set()
        } else if rHeld {
            NSCursor.crosshair.set()
        } else {
            switch ToolState.shared.tool {
            case .brush:
                brushCursor().set()
            case .hand:
                NSCursor.openHand.set()
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
            // Note on rotation: the cursor is currently a circle, which is
            // rotation-invariant. When we add tilt/rotation indicators (or
            // non-circular tip previews) per ARCHITECTURE.md decision 13's
            // forward implications, this is the place to apply view rotation.
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
        // Publish status every frame the canvas redraws — captures view transform
        // changes (zoom, pan, rotate, fit) without sprinkling publishStatus calls
        // through every mutator.
        publishStatus(cursorWindow: lastCursorWindow)
    }
}
