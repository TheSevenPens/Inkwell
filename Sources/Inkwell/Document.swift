import AppKit

final class Document: NSDocument {
    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let windowController = DocumentWindowController()
        addWindowController(windowController)
    }

    override func data(ofType typeName: String) throws -> Data {
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFeatureUnsupportedError,
            userInfo: [NSLocalizedDescriptionKey: "Save not yet implemented (Phase 5)."]
        )
    }

    override func read(from data: Data, ofType typeName: String) throws {
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFeatureUnsupportedError,
            userInfo: [NSLocalizedDescriptionKey: "Read not yet implemented (Phase 5)."]
        )
    }
}
