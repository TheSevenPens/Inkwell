import AppKit

/// Flow-grid layout for fixed-size icon buttons. Number of columns is
/// derived from the available width: `floor((W + gap) / (col + gap))`,
/// minimum 1. Used by `LeftPaneView`'s "Tools" section so the panel
/// reflows from one column to many as the user widens the left pane.
///
/// Buttons are positioned by `setFrame` in `layout()`; the buttons must
/// **not** carry width / height autolayout constraints (their sizes are
/// the grid's responsibility).
final class ToolsGridView: NSView {
    /// Width of each button slot in points.
    var columnWidth: CGFloat = 36
    /// Height of each button slot in points.
    var rowHeight: CGFloat = 32
    /// Gap between adjacent buttons (both axes).
    var gap: CGFloat = 4

    private(set) var buttons: [NSView] = []
    private var lastLaidOutWidth: CGFloat = -1

    /// Flipped so children stack top-down — matches how content is laid
    /// out elsewhere in the panel (the parent `LeftPaneView` is also flipped).
    override var isFlipped: Bool { true }

    func setButtons(_ list: [NSView]) {
        for old in buttons { old.removeFromSuperview() }
        buttons = list
        for b in list { addSubview(b) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func columnsForWidth(_ w: CGFloat) -> Int {
        guard w > 0 else { return 1 }
        return max(1, Int((w + gap) / (columnWidth + gap)))
    }

    private func heightForWidth(_ w: CGFloat) -> CGFloat {
        let cols = columnsForWidth(w)
        let n = buttons.count
        guard n > 0 else { return 0 }
        let rows = (n + cols - 1) / cols
        return CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * gap
    }

    override var intrinsicContentSize: NSSize {
        // Use the most recent laid-out width if known; fall back to bounds.
        let w = lastLaidOutWidth > 0 ? lastLaidOutWidth : bounds.width
        return NSSize(width: NSView.noIntrinsicMetric, height: heightForWidth(w))
    }

    override func layout() {
        super.layout()
        let cols = columnsForWidth(bounds.width)
        for (i, b) in buttons.enumerated() {
            let r = i / cols
            let c = i % cols
            let x = CGFloat(c) * (columnWidth + gap)
            let y = CGFloat(r) * (rowHeight + gap)
            b.frame = NSRect(x: x, y: y, width: columnWidth, height: rowHeight)
        }
        // If the available width changed, our intrinsic height changed too —
        // notify autolayout so the parent stack picks up the new height.
        if bounds.width != lastLaidOutWidth {
            lastLaidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
