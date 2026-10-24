import WebKit

// The Web Inspector: WebKit's own, on the tab in front — from the View menu
// and its keys, as from Inspect Element in a page's right-click menu. The
// keys are Chrome's and Arc's: ⌥⌘I for the inspector, ⌥⌘J for the console,
// ⌥⌘C to pick an element on the page.
//
// WebKit answers for its inspector only through names outside the public
// framework, so each is asked for before it is used; a WebKit without them
// leaves the menu doing nothing rather than the app falling over.
//
// In Chromium mode the same keys open Chromium's DevTools for the page,
// which has its console and its element picker in it.

extension Browser {
    /// ⌥⌘I: the inspector, or put away if it is up.
    func toggleInspector() {
        guard let inspector = inspector() else { return }
        if Inspector.asks(inspector, "isVisible") {
            Inspector.send(inspector, "close")
        } else {
            Inspector.send(inspector, "show")
        }
    }

    /// ⌥⌘J: the inspector, at its console.
    func showConsole() {
        guard let inspector = inspector() else { return }
        Inspector.send(inspector, "showConsole")
    }

    /// ⌥⌘C: the inspector, and the next click on the page picks what it
    /// shows. Again, and the picking stops.
    func inspectElement() {
        guard let inspector = inspector() else { return }
        if !Inspector.asks(inspector, "isVisible") { Inspector.send(inspector, "show") }
        Inspector.send(inspector, "toggleElementSelection")
    }

    /// The inspector of the tab in front — none for a blank tab, which has
    /// no page to look at. In Chromium mode there is none to hand back:
    /// the page's DevTools are opened instead, and nil said.
    private func inspector() -> NSObject? {
        guard let tab = active, !tab.isBlank else { return nil }
        guard WebEngine.current == .webkit else {
            tab.page?.showInspector()
            return nil
        }
        return Inspector.of(tab.web)
    }
}

/// WebKit's inspector of one view, through the names outside its public
/// framework, each asked for first.
@MainActor
enum Inspector {
    static func of(_ web: WKWebView) -> NSObject? {
        let get = NSSelectorFromString("_inspector")
        guard web.responds(to: get) else { return nil }
        return web.perform(get)?.takeUnretainedValue() as? NSObject
    }

    static func send(_ inspector: NSObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    static func asks(_ inspector: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: selector), to: Getter.self)(inspector, selector)
    }
}
