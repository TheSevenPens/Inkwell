import AppKit

/// A standardized panel section. Bundles a `CollapsibleSection` header with a
/// dedicated body container and persists the user's collapsed state under a
/// stable `id`. Add body views via `body.addArrangedSubview(_:)`; install the
/// whole section into a parent vertical stack via `install(in:)`.
///
/// Use this for new sections going forward. The three pre-existing sections
/// (Tools, Brush Settings, Layers) still use `CollapsibleSection` directly
/// because their body content is interleaved with custom layout. A migration
/// to `Section` would be a refactor, not a behavior change.
///
/// **Lifetime gotcha.** The disclosure button's `target` is the underlying
/// `CollapsibleSection` (weakly retained, like every NSControl target). If
/// the `Section` instance is allowed to deallocate, the chevron will still
/// rotate on click but the body won't toggle. **The owning view must hold
/// the `Section` in a stored property** — don't leave it as a local in a
/// `buildLayout()` method.
final class Section {
    let id: String

    /// The disclosure-triangle header row. Auto-installed by `install(in:)`;
    /// callers normally don't touch it directly.
    var header: NSStackView { collapsible.header }

    /// Container for the section's body views. Add subviews via
    /// `body.addArrangedSubview(_:)`. The whole stack is hidden / shown
    /// when the user toggles the disclosure.
    let body: NSStackView

    private let collapsible: CollapsibleSection

    init(id: String, title: String) {
        self.id = id
        self.collapsible = CollapsibleSection(title: title)

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 6
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        self.body = body

        // Register the body container as the single thing the disclosure
        // toggles. Adding more body items later still works (NSStackView
        // hides them along with itself).
        collapsible.registerBody(body)

        // Restore persisted collapsed state, if any.
        let key = Self.defaultsKey(id: id)
        if UserDefaults.standard.object(forKey: key) != nil {
            collapsible.setCollapsed(UserDefaults.standard.bool(forKey: key))
        }

        // Persist on every toggle.
        collapsible.onCollapsedChanged = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.collapsible.isCollapsed, forKey: key)
        }
    }

    /// Add this section's header and body to a parent vertical stack, with
    /// standardized intra-section and inter-section spacing.
    func install(in stack: NSStackView) {
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(4, after: header)   // tight gap between header and body
        stack.setCustomSpacing(12, after: body)    // looser gap before the next section
    }

    private static func defaultsKey(id: String) -> String {
        "Inkwell.SectionCollapsed.\(id)"
    }
}
