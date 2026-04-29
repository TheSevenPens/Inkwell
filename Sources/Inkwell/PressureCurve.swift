import Foundation
import CoreGraphics

/// Cubic-Bezier pressure response curve per ARCHITECTURE.md decision 11.
///
/// **Provisional.** The curve representation and editing UX are explicitly subject
/// to revision per the project owner's pending design input on pressure curves.
/// Curve evaluation is isolated here so the representation can change without
/// rippling through the brush engine.
///
/// Control point X-values are fixed at 1/3 and 2/3 along the curve parameter `t`.
/// With those Xs, the cubic-Bezier X(t) function reduces to t exactly, so callers
/// can pass the input pressure directly as `t` without inverting the curve.
struct PressureCurve: Codable, Equatable {
    /// Y of control point 1 (its X is fixed at 1/3).
    var c1y: CGFloat
    /// Y of control point 2 (its X is fixed at 2/3).
    var c2y: CGFloat

    /// Identity curve: y = t. No shaping.
    static let identity = PressureCurve(c1y: 1.0 / 3.0, c2y: 2.0 / 3.0)

    /// Slow start, fast finish (curve dips below the diagonal early).
    static let easeIn = PressureCurve(c1y: 0.10, c2y: 0.45)

    /// Fast start, slow finish (curve rises above the diagonal early).
    static let easeOut = PressureCurve(c1y: 0.55, c2y: 0.90)

    func evaluate(_ t: CGFloat) -> CGFloat {
        let tt = max(0, min(1, t))
        let mt = 1 - tt
        // P0=(0,0), P1=(1/3, c1y), P2=(2/3, c2y), P3=(1,1).
        // Y(t) = 3·(1-t)²·t·c1y + 3·(1-t)·t²·c2y + t³
        return 3 * mt * mt * tt * c1y
             + 3 * mt * tt * tt * c2y
             + tt * tt * tt
    }
}
