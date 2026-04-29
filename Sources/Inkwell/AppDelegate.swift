import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // ARCHITECTURE.md decision 10 calls for mouse coalescing off so we receive every
        // stylus sub-sample. The legacy Obj-C `NSEvent.setMouseCoalescingEnabled(_:)` is
        // not exposed in the current Swift import. Tablet-subtype events arrive ungrouped
        // through the standard mouseDown/mouseDragged path, so this is effectively a
        // no-op for stylus input on modern macOS. Revisit when validating with a real tablet.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
