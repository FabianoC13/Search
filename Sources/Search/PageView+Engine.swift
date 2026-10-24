import AppKit
import WebKit

// WebKit's view as the page a tab holds, whichever engine that is (see
// PageEngine.swift). Each member hands on to what the view already does:
// the tab keeps its observers and the browser its delegates, so a page in
// WebKit mode runs the same code it ran before there was a second engine.

extension PageView: PageEngine {
    var view: NSView { self }

    var backItemURL: URL? { backForwardList.backItem?.url }

    func reload(fromOrigin: Bool) {
        if fromOrigin { reloadFromOrigin() } else { reload() }
    }

    // WebKit's answer a navigation, which a page that only goes back has no
    // use for; these are the ones a tab calls.
    func goBack() { super.goBack() }
    func goForward() { super.goForward() }

    func setMuted(_ muted: Bool) { Muter.set(muted, on: self) }

    /// In Search's own world, where its page scripts are (see Web.world).
    func evaluate(_ script: String, then: ((Any?) -> Void)?) { evaluateInSearch(script, then: then) }

    func snapshot(width: CGFloat?, _ done: @escaping (NSImage?) -> Void) {
        let configuration = width.map { width in
            let made = WKSnapshotConfiguration()
            made.snapshotWidth = NSNumber(value: Double(width))
            return made
        }
        takeSnapshot(with: configuration) { image, _ in done(image) }
    }

    var restorableState: Any? { interactionState }
    func restore(_ state: Any) { interactionState = state }

    func showInspector() {
        if let inspector = Inspector.of(self) { Inspector.send(inspector, "show") }
    }

    /// Over the window in front, as ⌘P always opened it.
    func printPage() {
        guard let window = NSApp.keyWindow else { return }
        Browser.printing(self).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// What is left once the tab has taken its own off the view (see
    /// Tab.discard): the load, the delegates, the window.
    func tearDown() {
        stopLoading()
        navigationDelegate = nil
        uiDelegate = nil
        removeFromSuperview()
    }
}
