import Foundation

/// App-wide brush state: the four built-in brushes and the active selection.
/// Observers (canvas view, picker, inspector) register a closure and are notified
/// on selection or settings changes.
final class BrushPalette {
    static let shared = BrushPalette()

    private(set) var brushes: [Brush]
    private(set) var activeIndex: Int = 0

    var activeBrush: Brush { brushes[activeIndex] }

    private var observers: [() -> Void] = []

    private init() {
        brushes = Brush.builtins
    }

    func setActiveIndex(_ index: Int) {
        guard index >= 0, index < brushes.count, index != activeIndex else { return }
        activeIndex = index
        notify()
    }

    /// In-place edit of the active brush. Triggers one notification.
    func updateActive(_ update: (inout Brush) -> Void) {
        update(&brushes[activeIndex])
        notify()
    }

    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        observers.forEach { $0() }
    }
}
