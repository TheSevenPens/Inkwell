import Foundation
import CoreGraphics
import simd

struct ViewTransform {
    /// Window points per canvas pixel (zoom factor).
    var scale: CGFloat = 1.0
    /// Counterclockwise rotation in radians applied after scaling, before translation.
    var rotation: CGFloat = 0.0
    /// View-local position of canvas origin (canvas pixel 0,0) in window points,
    /// after scale + rotation.
    var offset: CGPoint = .zero

    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 64.0

    /// window_pt = R(canvas_pt) · scale + offset, where R is rotation by `rotation`.
    func windowToCanvas(_ point: CGPoint) -> CGPoint {
        let dx = (point.x - offset.x) / scale
        let dy = (point.y - offset.y) / scale
        let cosT = cos(rotation)
        let sinT = sin(rotation)
        // Inverse of R(θ) is R(-θ).
        return CGPoint(
            x: dx * cosT + dy * sinT,
            y: -dx * sinT + dy * cosT
        )
    }

    func canvasToWindow(_ point: CGPoint) -> CGPoint {
        let cosT = cos(rotation)
        let sinT = sin(rotation)
        let rx = point.x * cosT - point.y * sinT
        let ry = point.x * sinT + point.y * cosT
        return CGPoint(x: rx * scale + offset.x, y: ry * scale + offset.y)
    }

    mutating func zoom(by factor: CGFloat, at windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        let newScale = max(Self.minScale, min(Self.maxScale, scale * factor))
        scale = newScale
        anchorCanvasPoint(canvasPoint, at: windowPoint)
    }

    mutating func setScale(_ newScale: CGFloat, anchor windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        scale = max(Self.minScale, min(Self.maxScale, newScale))
        anchorCanvasPoint(canvasPoint, at: windowPoint)
    }

    /// Rotate by `delta` radians, keeping `windowPoint` fixed in the view.
    mutating func rotate(by delta: CGFloat, at windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        rotation += delta
        anchorCanvasPoint(canvasPoint, at: windowPoint)
    }

    /// Set rotation absolutely, keeping `windowPoint` fixed in the view.
    mutating func setRotation(_ newRotation: CGFloat, anchor windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        rotation = newRotation
        anchorCanvasPoint(canvasPoint, at: windowPoint)
    }

    /// Pin `canvasPoint` so it appears at `windowPoint` after the current scale + rotation.
    private mutating func anchorCanvasPoint(_ canvasPoint: CGPoint, at windowPoint: CGPoint) {
        let cosT = cos(rotation)
        let sinT = sin(rotation)
        let rx = canvasPoint.x * cosT - canvasPoint.y * sinT
        let ry = canvasPoint.x * sinT + canvasPoint.y * cosT
        offset = CGPoint(
            x: windowPoint.x - rx * scale,
            y: windowPoint.y - ry * scale
        )
    }

    /// Build a transform from canvas pixel coords directly to clip space.
    func clipTransform(viewBoundsPt: CGSize, viewDrawablePx: CGSize) -> simd_float4x4 {
        let pxPerPt = (viewBoundsPt.width > 0)
            ? Float(viewDrawablePx.width / viewBoundsPt.width)
            : 1.0
        let s = Float(scale)
        let cosT = Float(cos(rotation))
        let sinT = Float(sin(rotation))
        let ox = Float(offset.x)
        let oy = Float(offset.y)
        let drawableW = Float(viewDrawablePx.width)
        let drawableH = Float(viewDrawablePx.height)

        // window_pt.x = (cx·cos − cy·sin)·s + ox
        // window_pt.y = (cx·sin + cy·cos)·s + oy
        // drawable_px = pxPerPt · window_pt
        // clip       = 2·drawable_px / drawableSize − 1
        let kx = 2.0 * pxPerPt / drawableW
        let ky = 2.0 * pxPerPt / drawableH
        let mx_x = kx * s * cosT
        let mx_y = -kx * s * sinT
        let my_x = ky * s * sinT
        let my_y = ky * s * cosT
        let bx = kx * ox - 1.0
        let by = ky * oy - 1.0

        // simd_float4x4 takes columns. Column 0 is the cx coefficients,
        // column 1 the cy coefficients, column 3 the constant.
        return simd_float4x4(
            SIMD4<Float>(mx_x, my_x, 0, 0),
            SIMD4<Float>(mx_y, my_y, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(bx, by, 0, 1)
        )
    }
}
