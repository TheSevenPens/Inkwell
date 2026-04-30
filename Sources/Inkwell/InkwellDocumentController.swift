import AppKit

/// Custom `NSDocumentController` that intercepts `File → New` (and the
/// Dock-menu equivalent) to show our size-picker dialog before creating
/// the document. Other actions (Open, Open Recent, Save) inherit the
/// standard implementation.
///
/// `NSDocumentController` is a singleton — the *first* instance created
/// becomes the shared one. Instantiate this class early in
/// `AppDelegate.applicationDidFinishLaunching` (before any other code
/// touches `NSDocumentController.shared`) so AppKit picks ours.
final class InkwellDocumentController: NSDocumentController {

    override func newDocument(_ sender: Any?) {
        let dialog = NewDocumentDialog()
        guard let size = dialog.runModal() else { return }  // Cancel
        do {
            let doc = Document(canvasSize: size)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        }
    }
}
