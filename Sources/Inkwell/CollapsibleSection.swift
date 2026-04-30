import AppKit

/// Reusable disclosure-triangle header for a collapsible section.
///
/// Owns one disclosure NSButton, one title label, and a `body` array of views
/// that should hide / unhide as a unit when the user toggles. The body views
/// stay arranged-subviews of the caller's stack — this helper just flips
/// their `isHidden` flags. NSStackView excludes hidden arranged subviews from
/// layout, so the section collapses smoothly without further work.
final class CollapsibleSection {
    let header: NSStackView
    private let disclosure: NSButton
    private let label: NSTextField
    private(set) var bodyItems: [NSView] = []
    private(set) var isCollapsed: Bool = false

    /// Called whenever the user toggles the disclosure (or `setCollapsed(_:)`
    /// is invoked programmatically). Useful for persisting state.
    var onCollapsedChanged: (() -> Void)?

    init(title: String) {
        let button = NSButton()
        button.bezelStyle = .disclosure
        button.title = ""
        button.setButtonType(.onOff)
        button.state = .on  // expanded by default
        self.disclosure = button

        let lbl = NSTextField(labelWithString: title)
        lbl.font = .boldSystemFont(ofSize: 12)
        lbl.textColor = .secondaryLabelColor
        self.label = lbl

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.addArrangedSubview(button)
        row.addArrangedSubview(lbl)
        self.header = row

        button.target = self
        button.action = #selector(toggle(_:))
    }

    /// Add a body view that will hide / show with the section. The caller is
    /// also responsible for arranging the view in its own stack — this helper
    /// only tracks the reference for `isHidden` toggling.
    func registerBody(_ view: NSView) {
        bodyItems.append(view)
    }

    /// Convenience: also adds the view as an arranged subview of `stack`.
    func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        bodyItems.append(view)
    }

    /// Programmatically apply a collapsed state. Used to restore persisted
    /// state at panel creation time.
    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        disclosure.state = collapsed ? .off : .on
        for v in bodyItems {
            v.isHidden = collapsed
        }
        onCollapsedChanged?()
    }

    @objc private func toggle(_ sender: NSButton) {
        isCollapsed = (sender.state == .off)
        for v in bodyItems {
            v.isHidden = isCollapsed
        }
        onCollapsedChanged?()
    }
}
