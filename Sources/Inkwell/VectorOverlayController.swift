import Foundation

/// App-wide toggle for the vector-stroke debug overlay. When visible, the
/// compositor draws a polyline (the raw stylus samples connected by straight
/// segments) and a node marker at each sample on top of every visible vector
/// layer. Useful for inspecting stroke geometry and debugging the densifier.
///
/// State persists in UserDefaults so the toggle survives across app launches.
final class VectorOverlayController {
    static let shared = VectorOverlayController()

    private static let visibilityKey = "Inkwell.VectorOverlayVisible"

    private(set) var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: Self.visibilityKey)
            notify()
        }
    }

    private var observers: [() -> Void] = []

    private init() {
        self.isVisible = UserDefaults.standard.bool(forKey: Self.visibilityKey)
    }

    func toggleVisibility() {
        isVisible.toggle()
    }

    func setVisible(_ flag: Bool) {
        guard isVisible != flag else { return }
        isVisible = flag
    }

    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        observers.forEach { $0() }
    }
}
