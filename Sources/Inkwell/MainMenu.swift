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

    NSApp.mainMenu = mainMenu
}
