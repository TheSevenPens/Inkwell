import AppKit
import ObjectiveC

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        disableMouseCoalescingViaRuntime()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ARCHITECTURE.md decision 10 calls for mouse coalescing off so we receive
    /// every stylus sub-sample. The legacy Obj-C class method
    /// `+[NSEvent setMouseCoalescingEnabled:]` exists in the runtime but isn't
    /// surfaced through the Swift import — we reach it via `NSObject.method(for:)`
    /// and an unsafe cast. With this disabled, mouseDragged events arrive at
    /// the tablet's full sample rate (often 200+ Hz on Wacom) instead of the
    /// 60 Hz coalesced rate; high-frequency `tabletPoint` events also flow
    /// through the standard responder path uncoalesced.
    private func disableMouseCoalescingViaRuntime() {
        let selector = NSSelectorFromString("setMouseCoalescingEnabled:")
        guard NSEvent.responds(to: selector) else {
            NSLog("Inkwell: setMouseCoalescingEnabled: unavailable; tablet rate may be capped at refresh rate")
            return
        }
        typealias Function = @convention(c) (AnyClass, Selector, ObjCBool) -> Void
        let imp = NSEvent.method(for: selector)
        guard let imp else { return }
        let function = unsafeBitCast(imp, to: Function.self)
        function(NSEvent.self, selector, ObjCBool(false))
    }
}
