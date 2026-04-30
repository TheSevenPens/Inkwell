import Foundation

/// App-wide active tool. Brush palette and selection tools are mutually exclusive
/// at the high level; choosing a brush implies `.brush`.
final class ToolState {
    enum Tool: Equatable {
        case brush
        case selectRectangle
        case selectEllipse
        case selectLasso
    }

    static let shared = ToolState()

    private(set) var tool: Tool = .brush
    private var observers: [() -> Void] = []

    private init() {}

    func setTool(_ t: Tool) {
        guard tool != t else { return }
        tool = t
        notify()
    }

    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    private func notify() {
        observers.forEach { $0() }
    }
}
