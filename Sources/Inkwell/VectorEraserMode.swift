import Foundation

/// What the vector eraser does when it touches a stroke.
enum VectorEraserMode: String, CaseIterable {
    /// Mode 1 — delete any stroke whose footprint the eraser disc touches,
    /// in its entirety. The simplest semantic and the V1 default.
    case wholeStroke = "wholeStroke"

    /// Mode 2 — split each touched stroke at the raw stylus samples that
    /// fall inside the eraser disc, dropping those samples and producing
    /// zero or more sub-strokes from the remaining runs of consecutive
    /// non-erased samples. Caveat: cuts snap to sample boundaries, so a
    /// dense polyline gives clean cuts and a sparse one may leave a stub.
    case region = "region"

    /// Mode 3 — from the closest sample on the touched stroke, walk the
    /// polyline forward and backward until a segment of the stroke
    /// intersects either a non-adjacent segment of the same stroke (a
    /// self-intersection) or any segment of any other stroke. The
    /// run between the two stop points is removed; up to two sub-strokes
    /// remain. Useful for cleaning up linework where lines cross.
    case toIntersection = "toIntersection"

    var displayName: String {
        switch self {
        case .wholeStroke: return "Whole Stroke"
        case .region: return "Touched Region"
        case .toIntersection: return "To Intersection"
        }
    }
}

/// Persists the active vector-eraser mode in UserDefaults and notifies
/// observers (the menu, primarily) when it changes.
final class VectorEraserController {
    static let shared = VectorEraserController()
    private static let key = "Inkwell.VectorEraserMode"

    private(set) var mode: VectorEraserMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            notify()
        }
    }

    private var observers: [() -> Void] = []

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let parsed = VectorEraserMode(rawValue: raw) {
            mode = parsed
        } else {
            mode = .wholeStroke
        }
    }

    func setMode(_ newMode: VectorEraserMode) {
        guard newMode != mode else { return }
        mode = newMode
    }

    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        observers.forEach { $0() }
    }
}
