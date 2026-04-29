import Foundation
import CoreGraphics
import simd

struct ViewTransform {
    /// Window points per canvas pixel (zoom factor).
    var scale: CGFloat = 1.0
    /// View-local position of canvas origin (canvas pixel 0,0) in window points.
    var offset: CGPoint = .zero

    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 64.0

    func windowToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - offset.x) / scale,
            y: (point.y - offset.y) / scale
        )
    }

    mutating func zoom(by factor: CGFloat, at windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        let newScale = max(Self.minScale, min(Self.maxScale, scale * factor))
        scale = newScale
        offset = CGPoint(
            x: windowPoint.x - canvasPoint.x * scale,
            y: windowPoint.y - canvasPoint.y * scale
        )
    }

    mutating func setScale(_ newScale: CGFloat, anchor windowPoint: CGPoint) {
        let canvasPoint = windowToCanvas(windowPoint)
        scale = max(Self.minScale, min(Self.maxScale, newScale))
        offset = CGPoint(
            x: windowPoint.x - canvasPoint.x * scale,
            y: windowPoint.y - canvasPoint.y * scale
        )
    }

    /// Build a transform from canvas pixel coords directly to clip space.
    /// Used by both the paper-background pass (full canvas size) and per-tile draws
    /// (tile origin + corner * tile size).
    func clipTransform(viewBoundsPt: CGSize, viewDrawablePx: CGSize) -> simd_float4x4 {
        let pxPerPt = (viewBoundsPt.width > 0)
            ? Float(viewDrawablePx.width / viewBoundsPt.width)
            : 1.0
        let s = Float(scale)
        let ox = Float(offset.x)
        let oy = Float(offset.y)
        let drawableW = Float(viewDrawablePx.width)
        let drawableH = Float(viewDrawablePx.height)

        // canvas_pixel_x → window_pt: ox + canvas_pixel_x * s
        // window_pt → drawable_px: * pxPerPt
        // drawable_px → clip: 2 * px / drawableSize - 1
        //
        // clip_x = (2 * pxPerPt * s / drawableW) * canvas_pixel_x + (2 * pxPerPt * ox / drawableW - 1)
        let mx = 2.0 * pxPerPt * s / drawableW
        let my = 2.0 * pxPerPt * s / drawableH
        let bx = 2.0 * pxPerPt * ox / drawableW - 1.0
        let by = 2.0 * pxPerPt * oy / drawableH - 1.0

        return simd_float4x4(
            SIMD4<Float>(mx, 0, 0, 0),
            SIMD4<Float>(0, my, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(bx, by, 0, 1)
        )
    }
}
