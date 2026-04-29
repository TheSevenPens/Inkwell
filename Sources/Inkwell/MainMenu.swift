import AppKit

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
