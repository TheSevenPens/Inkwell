import AppKit

/// Singleton that populates the File → Open Recent submenu on demand.
/// NSDocumentController's recent-documents tracking fires automatically when
/// documents open or save successfully; this class just renders the list.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    static let shared = RecentDocumentsMenu()

    func attach(to menu: NSMenu) {
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = menu.addItem(withTitle: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for url in urls {
            let item = menu.addItem(
                withTitle: url.lastPathComponent,
                action: #selector(openRecent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
        }
        menu.addItem(.separator())
        let clear = menu.addItem(
            withTitle: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clear.target = NSDocumentController.shared
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

func installMainMenu() {
    let mainMenu = NSMenu()

    // App menu
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "About Inkwell",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Hide Inkwell",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    )
    let hideOthers = appMenu.addItem(
        withTitle: "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
        withTitle: "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Quit Inkwell",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    // File menu
    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(
        withTitle: "New",
        action: #selector(NSDocumentController.newDocument(_:)),
        keyEquivalent: "n"
    )
    fileMenu.addItem(
        withTitle: "Open\u{2026}",
        action: #selector(NSDocumentController.openDocument(_:)),
        keyEquivalent: "o"
    )
    let openRecent = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
    let openRecentMenu = NSMenu(title: "Open Recent")
    openRecent.submenu = openRecentMenu
    RecentDocumentsMenu.shared.attach(to: openRecentMenu)
    fileMenu.addItem(.separator())
    fileMenu.addItem(
        withTitle: "Close",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    fileMenu.addItem(
        withTitle: "Save",
        action: #selector(NSDocument.save(_:)),
        keyEquivalent: "s"
    )
    let saveAs = fileMenu.addItem(
        withTitle: "Save As\u{2026}",
        action: #selector(NSDocument.saveAs(_:)),
        keyEquivalent: "s"
    )
    saveAs.keyEquivalentModifierMask = [.command, .shift]

    fileMenu.addItem(.separator())
    let exportItem = fileMenu.addItem(withTitle: "Export", action: nil, keyEquivalent: "")
    let exportMenu = NSMenu(title: "Export")
    exportItem.submenu = exportMenu
    exportMenu.addItem(
        withTitle: "PNG\u{2026}",
        action: #selector(Document.exportAsPNG(_:)),
        keyEquivalent: ""
    )
    exportMenu.addItem(
        withTitle: "JPEG\u{2026}",
        action: #selector(Document.exportAsJPEG(_:)),
        keyEquivalent: ""
    )
    exportMenu.addItem(
        withTitle: "PSD\u{2026}",
        action: #selector(Document.exportAsPSD(_:)),
        keyEquivalent: ""
    )

    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    // Edit menu
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
        withTitle: "Undo",
        action: Selector(("undo:")),
        keyEquivalent: "z"
    )
    let redoItem = editMenu.addItem(
        withTitle: "Redo",
        action: Selector(("redo:")),
        keyEquivalent: "z"
    )
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    // Backspace = U+0008. macOS displays it as ⌫ in menus.
    let clearItem = editMenu.addItem(
        withTitle: "Clear",
        action: #selector(Document.clearAction(_:)),
        keyEquivalent: "\u{8}"
    )
    clearItem.keyEquivalentModifierMask = []
    editMenu.addItem(.separator())
    editMenu.addItem(
        withTitle: "Select All",
        action: #selector(CanvasView.selectAll(_:)),
        keyEquivalent: "a"
    )
    editMenu.addItem(
        withTitle: "Deselect",
        action: #selector(CanvasView.deselect(_:)),
        keyEquivalent: "d"
    )
    let invertItem = editMenu.addItem(
        withTitle: "Invert Selection",
        action: #selector(CanvasView.invertSelection(_:)),
        keyEquivalent: "i"
    )
    invertItem.keyEquivalentModifierMask = [.command, .shift]
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    // Image menu (Phase 10 — document-level transforms)
    let imageItem = NSMenuItem()
    let imageMenu = NSMenu(title: "Image")
    imageMenu.addItem(
        withTitle: "Rotate 180°",
        action: #selector(Document.imageRotate180(_:)),
        keyEquivalent: ""
    )
    imageMenu.addItem(
        withTitle: "Rotate 90° CW",
        action: #selector(Document.imageRotate90CW(_:)),
        keyEquivalent: ""
    )
    imageMenu.addItem(
        withTitle: "Rotate 90° CCW",
        action: #selector(Document.imageRotate90CCW(_:)),
        keyEquivalent: ""
    )
    imageMenu.addItem(.separator())
    imageMenu.addItem(
        withTitle: "Flip Horizontal",
        action: #selector(Document.imageFlipHorizontal(_:)),
        keyEquivalent: ""
    )
    imageMenu.addItem(
        withTitle: "Flip Vertical",
        action: #selector(Document.imageFlipVertical(_:)),
        keyEquivalent: ""
    )
    imageItem.submenu = imageMenu
    mainMenu.addItem(imageItem)

    // View menu
    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
        withTitle: "Fit Window",
        action: #selector(CanvasView.fitToWindow(_:)),
        keyEquivalent: "0"
    )
    viewMenu.addItem(
        withTitle: "Actual Size",
        action: #selector(CanvasView.actualSize(_:)),
        keyEquivalent: "1"
    )
    viewItem.submenu = viewMenu
    mainMenu.addItem(viewItem)

    // Window menu
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    let fitToScreenItem = windowMenu.addItem(
        withTitle: "Fit to Screen",
        action: #selector(WindowMenuTarget.fitToScreen(_:)),
        keyEquivalent: "f"
    )
    fitToScreenItem.keyEquivalentModifierMask = [.command, .control]
    fitToScreenItem.target = WindowMenuTarget.shared
    let nextDisplayItem = windowMenu.addItem(
        withTitle: "Move to Next Display",
        action: #selector(WindowMenuTarget.moveToNextDisplay(_:)),
        keyEquivalent: "n"
    )
    nextDisplayItem.keyEquivalentModifierMask = [.command, .control]
    nextDisplayItem.target = WindowMenuTarget.shared
    windowMenu.addItem(.separator())
    windowMenu.addItem(
        withTitle: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
    )
    windowMenu.addItem(
        withTitle: "Zoom",
        action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""
    )
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    // Debug menu
    let debugItem = NSMenuItem()
    let debugMenu = NSMenu(title: "Debug")
    let debugToolbarItem = debugMenu.addItem(
        withTitle: "Show Debug Toolbar",
        action: #selector(DebugMenuTarget.toggleDebugToolbar(_:)),
        keyEquivalent: ""
    )
    debugToolbarItem.target = DebugMenuTarget.shared
    debugToolbarItem.state = DebugBarController.shared.isVisible ? .on : .off
    DebugMenuTarget.shared.toolbarMenuItem = debugToolbarItem
    debugItem.submenu = debugMenu
    mainMenu.addItem(debugItem)

    NSApp.mainMenu = mainMenu
}

/// Owner of the Window menu's geometry actions. Operates on the current key
/// window, so the menu item is enabled whenever a window is keyed up.
final class WindowMenuTarget: NSObject {
    static let shared = WindowMenuTarget()

    /// Resize and reposition the key window so its frame fills the visible
    /// area of whichever screen currently contains its center (or the main
    /// screen, if the window is entirely off-screen).
    @objc func fitToScreen(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screenContaining(point: center)
            ?? window.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        // Relax the window's minimum size so internal autolayout can't refuse
        // a smaller frame. The user can drag larger from there.
        window.contentMinSize = NSSize(width: 600, height: 400)
        window.minSize = NSSize(width: 600, height: 400)

        let margin: CGFloat = 16
        let target = NSRect(
            x: visible.minX + margin,
            y: visible.minY + margin,
            width: max(600, visible.width - margin * 2),
            height: max(400, visible.height - margin * 2)
        )
        // animate:false so the resize is immediate and predictable when the
        // window is already partly off-screen.
        window.setFrame(target, display: true, animate: false)
    }

    /// Move the key window to the next available screen, preserving size
    /// (clamped to fit) and relative position within that screen.
    @objc func moveToNextDisplay(_ sender: Any?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            NSSound.beep()
            return
        }
        let currentScreen = window.screen ?? NSScreen.main ?? screens[0]
        let currentIndex = screens.firstIndex(of: currentScreen) ?? 0
        let nextScreen = screens[(currentIndex + 1) % screens.count]
        let visible = nextScreen.visibleFrame
        let margin: CGFloat = 12
        let oldFrame = window.frame
        let w = min(oldFrame.width, visible.width - margin * 2)
        let h = min(oldFrame.height, visible.height - margin * 2)
        let newFrame = NSRect(
            x: visible.minX + (visible.width - w) / 2.0,
            y: visible.minY + (visible.height - h) / 2.0,
            width: w,
            height: h
        )
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if NSPointInRect(point, screen.frame) { return screen }
        }
        return nil
    }
}

/// Owner of the Debug menu's actions; keeps a reference so menu item state
/// can be flipped on/off as the controller changes.
final class DebugMenuTarget: NSObject {
    static let shared = DebugMenuTarget()
    weak var toolbarMenuItem: NSMenuItem?

    override init() {
        super.init()
        DebugBarController.shared.addObserver { [weak self] in
            self?.toolbarMenuItem?.state = DebugBarController.shared.isVisible ? .on : .off
        }
    }

    @objc func toggleDebugToolbar(_ sender: NSMenuItem) {
        DebugBarController.shared.toggleVisibility()
    }
}
