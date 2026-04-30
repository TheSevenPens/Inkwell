import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let inkwellLayer = NSPasteboard.PasteboardType("com.thesevenpens.Inkwell.layer")
}

/// Phase 6 layer panel: outline view with eye toggle, mask indicator, and editable
/// names. Active-layer opacity, blend mode, edit target (Layer | Mask), and mask
/// management at the top. Drag-to-reorder.
final class LayerPanelView: NSView {
    private(set) weak var canvas: Canvas?

    private var outline: NSOutlineView!
    private var scrollView: NSScrollView!
    private var opacitySlider: NSSlider!
    private var opacityValueLabel: NSTextField!
    private var blendPopup: NSPopUpButton!
    private var editTargetControl: NSSegmentedControl!
    private var addMaskButton: NSButton!
    private var removeMaskButton: NSButton!
    private var bgColorWell: NSColorWell!
    private var bgColorRow: NSStackView!

    private var refreshing = false
    private var section: CollapsibleSection!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(canvas: Canvas) {
        self.canvas = canvas
        canvas.addObserver { [weak self] in self?.reload() }
        reload()
    }

    private func buildLayout() {
        section = CollapsibleSection(title: "Layers")

        // Edit-target row
        let editRow = NSStackView()
        editRow.orientation = .horizontal
        editRow.spacing = 6
        let editLabel = NSTextField(labelWithString: "Edit")
        editLabel.font = .systemFont(ofSize: 11)
        editLabel.textColor = .secondaryLabelColor
        editTargetControl = NSSegmentedControl(labels: ["Layer", "Mask"], trackingMode: .selectOne, target: self, action: #selector(editTargetChanged(_:)))
        editTargetControl.controlSize = .small
        editTargetControl.selectedSegment = 0
        editLabel.translatesAutoresizingMaskIntoConstraints = false
        editTargetControl.translatesAutoresizingMaskIntoConstraints = false
        editRow.addArrangedSubview(editLabel)
        editRow.addArrangedSubview(editTargetControl)
        editLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // Opacity row
        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 6
        let opLabel = NSTextField(labelWithString: "Opacity")
        opLabel.font = .systemFont(ofSize: 11)
        opLabel.textColor = .secondaryLabelColor
        opacitySlider = NSSlider(
            value: 1.0,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(opacityChanged(_:))
        )
        opacitySlider.controlSize = .small
        opacityValueLabel = NSTextField(labelWithString: "100%")
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        opacityValueLabel.textColor = .tertiaryLabelColor
        opacityValueLabel.alignment = .right
        opLabel.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityRow.addArrangedSubview(opLabel)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityValueLabel)
        opLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // Blend row
        let blendRow = NSStackView()
        blendRow.orientation = .horizontal
        blendRow.spacing = 6
        let blendLabel = NSTextField(labelWithString: "Blend")
        blendLabel.font = .systemFont(ofSize: 11)
        blendLabel.textColor = .secondaryLabelColor
        blendPopup = NSPopUpButton()
        for mode in LayerBlendMode.allCases {
            blendPopup.addItem(withTitle: mode.displayName)
            blendPopup.lastItem?.representedObject = mode
        }
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged(_:))
        blendPopup.controlSize = .small
        blendLabel.translatesAutoresizingMaskIntoConstraints = false
        blendPopup.translatesAutoresizingMaskIntoConstraints = false
        blendRow.addArrangedSubview(blendLabel)
        blendRow.addArrangedSubview(blendPopup)
        blendLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // Background-color row. Visible only when the active layer is a
        // BackgroundLayer; hidden otherwise. The NSStackView excludes
        // hidden arranged subviews from layout, so the panel collapses
        // around it when not applicable.
        bgColorRow = NSStackView()
        bgColorRow.orientation = .horizontal
        bgColorRow.spacing = 6
        let bgLabel = NSTextField(labelWithString: "Color")
        bgLabel.font = .systemFont(ofSize: 11)
        bgLabel.textColor = .secondaryLabelColor
        bgColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 36, height: 22))
        bgColorWell.target = self
        bgColorWell.action = #selector(bgColorChanged(_:))
        bgLabel.translatesAutoresizingMaskIntoConstraints = false
        bgColorWell.translatesAutoresizingMaskIntoConstraints = false
        bgLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        bgColorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        bgColorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        bgColorRow.addArrangedSubview(bgLabel)
        bgColorRow.addArrangedSubview(bgColorWell)
        bgColorRow.isHidden = true

        // Outline
        outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .inset
        outline.indentationPerLevel = 16
        outline.rowSizeStyle = .small
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(outlineClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.title = "Layer"
        column.width = 220
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.registerForDraggedTypes([.inkwellLayer])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = outline
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom toolbars (two rows). The four "add layer kind" buttons are
        // collapsed into a single pull-down so the toolbar stays compact and
        // future layer kinds are a single new menu item, not a new button.
        let layerToolbar = NSStackView()
        layerToolbar.orientation = .horizontal
        layerToolbar.spacing = 4
        let addPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        addPopup.bezelStyle = .roundRect
        addPopup.controlSize = .small
        // First item of a pull-down is the always-visible title; the menu
        // entries that follow are the actual actions.
        addPopup.addItem(withTitle: "+")
        let addItems: [(String, Selector)] = [
            ("Layer", #selector(newLayer(_:))),
            ("Vector Layer", #selector(newVectorLayer(_:))),
            ("Background Layer", #selector(newBackgroundLayer(_:))),
            ("Group", #selector(newGroup(_:)))
        ]
        for (title, action) in addItems {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            addPopup.menu?.addItem(item)
        }
        let dupBtn = NSButton(title: "Dup", target: self, action: #selector(duplicateLayer(_:)))
        let delBtn = NSButton(title: "Del", target: self, action: #selector(deleteLayer(_:)))
        layerToolbar.addArrangedSubview(addPopup)
        for b in [dupBtn, delBtn] {
            b.bezelStyle = .roundRect
            b.controlSize = .small
            layerToolbar.addArrangedSubview(b)
        }

        let maskToolbar = NSStackView()
        maskToolbar.orientation = .horizontal
        maskToolbar.spacing = 4
        addMaskButton = NSButton(title: "Add Mask", target: self, action: #selector(addMask(_:)))
        removeMaskButton = NSButton(title: "Remove Mask", target: self, action: #selector(removeMask(_:)))
        for b in [addMaskButton!, removeMaskButton!] {
            b.bezelStyle = .roundRect
            b.controlSize = .small
            maskToolbar.addArrangedSubview(b)
        }

        let master = NSStackView()
        master.orientation = .vertical
        master.spacing = 6
        master.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        master.alignment = .leading
        master.distribution = .fill
        master.translatesAutoresizingMaskIntoConstraints = false
        master.addArrangedSubview(section.header)
        section.add(layerToolbar, to: master)
        section.add(editRow, to: master)
        section.add(opacityRow, to: master)
        section.add(blendRow, to: master)
        section.add(bgColorRow, to: master)
        section.add(scrollView, to: master)
        section.add(maskToolbar, to: master)
        master.setCustomSpacing(8, after: layerToolbar)
        master.setCustomSpacing(8, after: blendRow)
        master.setCustomSpacing(6, after: scrollView)

        addSubview(master)
        NSLayoutConstraint.activate([
            master.topAnchor.constraint(equalTo: topAnchor),
            master.leadingAnchor.constraint(equalTo: leadingAnchor),
            master.trailingAnchor.constraint(equalTo: trailingAnchor),
            master.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            scrollView.widthAnchor.constraint(equalTo: master.widthAnchor, constant: -16)
        ])
    }

    func reload() {
        guard let canvas else { return }
        refreshing = true
        defer { refreshing = false }
        outline.reloadData()
        for layer in canvas.rootLayers where layer is GroupLayer {
            outline.expandItem(layer, expandChildren: true)
        }
        if let activeId = canvas.activeLayerId, let layer = canvas.findLayer(activeId) {
            let row = outline.row(forItem: layer)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        if let active = canvas.activeLayer {
            opacitySlider.doubleValue = Double(active.opacity)
            opacityValueLabel.stringValue = "\(Int(active.opacity * 100))%"
            if let item = blendPopup.itemArray.first(where: { ($0.representedObject as? LayerBlendMode) == active.blendMode }) {
                blendPopup.select(item)
            }
        }
        // Mask UI state
        let activeBitmap = canvas.activeBitmapLayer
        let hasMask = activeBitmap?.mask != nil
        editTargetControl.setEnabled(hasMask, forSegment: 1)
        editTargetControl.selectedSegment = canvas.editingMask ? 1 : 0
        addMaskButton.isEnabled = activeBitmap != nil && !hasMask
        removeMaskButton.isEnabled = hasMask
        // Background-color row visibility + value.
        if let bg = canvas.activeLayer as? BackgroundLayer {
            bgColorRow.isHidden = false
            bgColorWell.color = NSColor(
                srgbRed: bg.color.r,
                green: bg.color.g,
                blue: bg.color.b,
                alpha: bg.color.a
            )
        } else {
            bgColorRow.isHidden = true
        }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        guard !refreshing, let canvas, let activeId = canvas.activeLayerId else { return }
        canvas.setOpacity(activeId, opacity: CGFloat(sender.doubleValue))
        opacityValueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func blendChanged(_ sender: NSPopUpButton) {
        guard !refreshing, let canvas, let activeId = canvas.activeLayerId,
              let mode = sender.selectedItem?.representedObject as? LayerBlendMode else { return }
        canvas.setBlendMode(activeId, mode: mode)
    }

    @objc private func editTargetChanged(_ sender: NSSegmentedControl) {
        guard !refreshing, let canvas else { return }
        canvas.setEditingMask(sender.selectedSegment == 1)
    }

    @objc private func newLayer(_ sender: Any?) { canvas?.addNewBitmapLayer() }
    @objc private func newVectorLayer(_ sender: Any?) { canvas?.addNewVectorLayer() }
    @objc private func newBackgroundLayer(_ sender: Any?) { canvas?.addNewBackgroundLayer() }
    @objc private func newGroup(_ sender: Any?) { canvas?.addNewGroup() }

    @objc private func bgColorChanged(_ sender: NSColorWell) {
        guard !refreshing, let canvas,
              let bg = canvas.activeLayer as? BackgroundLayer else { return }
        let ns = sender.color.usingColorSpace(.sRGB) ?? sender.color
        bg.color = ColorRGBA(
            r: ns.redComponent,
            g: ns.greenComponent,
            b: ns.blueComponent,
            a: 1
        )
        canvas.notifyChanged()
    }

    @objc private func duplicateLayer(_ sender: Any?) {
        guard let canvas, let id = canvas.activeLayerId else { return }
        canvas.duplicateLayer(id)
    }

    @objc private func deleteLayer(_ sender: Any?) {
        guard let canvas, let id = canvas.activeLayerId else { return }
        canvas.deleteLayer(id)
    }

    @objc private func addMask(_ sender: Any?) { canvas?.addMaskToActiveLayer() }
    @objc private func removeMask(_ sender: Any?) { canvas?.removeMaskFromActiveLayer() }

    @objc private func outlineClicked(_ sender: Any?) {
        guard !refreshing, let canvas else { return }
        let row = outline.selectedRow
        guard row >= 0, let layer = outline.item(atRow: row) as? LayerNode else { return }
        canvas.setActiveLayer(layer.id)
    }

    fileprivate func toggleVisibility(of layer: LayerNode) {
        guard let canvas else { return }
        canvas.setVisible(layer.id, visible: !layer.isVisible)
    }

    fileprivate func renameLayer(_ layer: LayerNode, to newName: String) {
        guard let canvas else { return }
        canvas.renameLayer(layer.id, to: newName)
    }
}

extension LayerPanelView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return canvas?.rootLayers.count ?? 0
        }
        if let group = item as? GroupLayer {
            return group.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return canvas!.rootLayers[index]
        }
        if let group = item as? GroupLayer {
            return group.children[index]
        }
        fatalError("Bad item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is GroupLayer
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let layer = item as? LayerNode else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(layer.id.uuidString, forType: .inkwellLayer)
        return pbItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if index == NSOutlineViewDropOnItemIndex { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let canvas, let pbItems = info.draggingPasteboard.pasteboardItems else { return false }
        let newParent = item as? GroupLayer
        var ok = false
        for pbItem in pbItems {
            guard let idString = pbItem.string(forType: .inkwellLayer),
                  let id = UUID(uuidString: idString) else { continue }
            var insertIndex = index
            if let parent = canvas.parentOfLayer(id), parent === newParent,
               let srcIndex = parent.children.firstIndex(where: { $0.id == id }),
               srcIndex < index {
                insertIndex -= 1
            } else if newParent == nil,
                      canvas.parentOfLayer(id) == nil,
                      let srcIndex = canvas.rootLayers.firstIndex(where: { $0.id == id }),
                      srcIndex < index {
                insertIndex -= 1
            }
            canvas.moveLayer(id, toIndex: insertIndex, in: newParent)
            ok = true
        }
        return ok
    }
}

extension LayerPanelView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let layer = item as? LayerNode else { return nil }
        let cell = LayerRowCell()
        cell.configure(with: layer, panel: self)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        guard let canvas else { return }
        let row = outline.selectedRow
        if row >= 0, let layer = outline.item(atRow: row) as? LayerNode {
            canvas.setActiveLayer(layer.id)
        }
    }
}

private final class LayerRowCell: NSTableCellView {
    private weak var layerNode: LayerNode?
    private weak var panel: LayerPanelView?

    private let eyeButton = NSButton()
    private let nameField = NSTextField()
    private let maskBadge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        eyeButton.bezelStyle = .smallSquare
        eyeButton.isBordered = false
        eyeButton.target = self
        eyeButton.action = #selector(toggleEye(_:))
        eyeButton.imagePosition = .imageOnly
        eyeButton.translatesAutoresizingMaskIntoConstraints = false

        nameField.isEditable = true
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.target = self
        nameField.action = #selector(nameEdited(_:))
        nameField.font = .systemFont(ofSize: 12)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        maskBadge.font = .boldSystemFont(ofSize: 10)
        maskBadge.textColor = .secondaryLabelColor
        maskBadge.alignment = .right
        maskBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(eyeButton)
        addSubview(nameField)
        addSubview(maskBadge)
        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),
            eyeButton.heightAnchor.constraint(equalToConstant: 18),
            nameField.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: maskBadge.leadingAnchor, constant: -4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            maskBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            maskBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            maskBadge.widthAnchor.constraint(equalToConstant: 18)
        ])
    }

    func configure(with node: LayerNode, panel: LayerPanelView) {
        self.layerNode = node
        self.panel = panel
        nameField.stringValue = node.name
        let symbolName = node.isVisible ? "eye" : "eye.slash"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            eyeButton.image = img
        }
        if let bitmap = node as? BitmapLayer, bitmap.mask != nil {
            maskBadge.stringValue = "M"
        } else {
            maskBadge.stringValue = ""
        }
    }

    @objc private func toggleEye(_ sender: Any?) {
        guard let node = layerNode, let panel else { return }
        panel.toggleVisibility(of: node)
    }

    @objc private func nameEdited(_ sender: NSTextField) {
        guard let node = layerNode, let panel else { return }
        panel.renameLayer(node, to: sender.stringValue)
    }
}
