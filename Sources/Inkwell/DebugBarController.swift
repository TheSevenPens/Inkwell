import Foundation

/// App-wide toggle for the debug toolbar. Visibility is persisted in UserDefaults
/// so the bar's state survives across app launches.
final class DebugBarController {
    static let shared = DebugBarController()

    private static let visibilityKey = "Inkwell.DebugBarVisible"

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
