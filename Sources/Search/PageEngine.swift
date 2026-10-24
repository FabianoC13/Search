import AppKit

// Two engines can draw a page: WebKit, the one already inside every Mac, and
// Chromium, an add-on downloaded on request (see Chromium/). One app, one
// switch in Settings › Engine. The choice is read once, at launch, and holds
// for the life of the process: Chromium can be started only once in a
// process and never unloaded, so switching saves the session and relaunches.
//
// The engine not chosen costs nothing. In WebKit mode Chromium is never
// loaded. In Chromium mode no WebKit object is made — no web view, no data
// store, no process pool, no extension controller, no content blocker — so
// none of WebKit's processes start.

/// Which engine draws pages in this process. Not `Engine`: that is the
/// search engine (Engine.swift).
enum WebEngine: String, CaseIterable {
    case webkit, chromium

    /// The setting, in Store.settings: what the next launch should run.
    nonisolated static let key = "web.engine"
    /// Set just before a relaunch that switches engines, cleared by the
    /// launch that reads it: that launch keeps the session even with
    /// "Start with a fresh window" on.
    nonisolated static let switchingKey = "web.engine.switching"
    /// Set while Chromium is starting, cleared once its first page is up.
    /// Still there at the next launch means Chromium took the last one down:
    /// that launch runs WebKit, and says so in Settings.
    nonisolated static let startingKey = "web.engine.starting"

    /// What the setting asks for.
    nonisolated static var chosen: WebEngine {
        Store.settings.string(forKey: key).flatMap(WebEngine.init) ?? .webkit
    }

    /// What this process runs, decided the first time anyone asks and never
    /// again. Chromium only when it is chosen, its add-on is installed and
    /// trusted, it didn't bring the last launch down, and it started.
    @MainActor static let current: WebEngine = resolve()

    /// Why Chromium was chosen and this process runs WebKit anyway, for
    /// Settings to say. Nil when it runs what was chosen.
    @MainActor private(set) static var fallback: String?

    @MainActor private static func resolve() -> WebEngine {
        guard chosen == .chromium else { return .webkit }
        if Store.settings.bool(forKey: startingKey) {
            Store.settings.removeObject(forKey: startingKey)
            fallback = "Chromium closed unexpectedly while starting, so Search opened with WebKit."
            return .webkit
        }
        switch ChromiumRuntime.start() {
        case .started:
            return .chromium
        case .failed(let reason):
            fallback = reason
            return .webkit
        }
    }

    var title: String { self == .webkit ? "WebKit" : "Chromium" }
}

/// One tab's page, whichever engine draws it. Tab holds one of these; the
/// stages host its `view`. WebKit's PageView conforms with one-line
/// forwards (PageView+Engine.swift); Chromium's is ChromiumPage.
@MainActor protocol PageEngine: AnyObject {
    /// What the stage puts in the window. Stable for the page's life:
    /// reparenting it moves the page, it never reloads it.
    var view: NSView { get }
    var url: URL? { get }
    var isLoading: Bool { get }
    /// Where Back would go, if anywhere.
    var backItemURL: URL? { get }
    var pageZoom: CGFloat { get set }

    func open(_ url: URL)
    func reload(fromOrigin: Bool)
    func stopLoading()
    func goBack()
    func goForward()
    func setMuted(_ muted: Bool)

    /// Runs `script` in the page. `then` gets the result where the engine
    /// can return one, nil where it can't (Chromium).
    func evaluate(_ script: String, then: ((Any?) -> Void)?)
    /// A picture of what is on screen, `width` points wide when given.
    /// Nil where the engine can't take one.
    func snapshot(width: CGFloat?, _ done: @escaping (NSImage?) -> Void)
    /// What it takes to bring the page back as it was — its back list, its
    /// scroll — when the tab sleeps. Nil where the engine keeps none.
    var restorableState: Any? { get }
    func restore(_ state: Any)

    /// Web Inspector, or Chromium's DevTools.
    func showInspector()
    func printPage()

    /// Put the page down for good: stop it, drop every handler, let its
    /// process go.
    func tearDown()
}

/// What a page tells its tab, for an engine without key-value observing
/// (Chromium). WebKit keeps its observers and Browser's delegates as they
/// are. Every call arrives on the main thread.
@MainActor protocol PageEventSink: AnyObject {
    func pageTitle(_ title: String)
    /// The main frame's address, including pushState and fragment moves.
    func pageURL(_ url: URL)
    func pageProgress(_ progress: Double)
    func pageLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool)
    /// A new document in the main frame.
    func pageCommitted()
    /// The main frame finished loading.
    func pageFinished()
    /// The main frame failed to load. `code` is an NSURLError code (the
    /// engine maps its own), never NSURLErrorCancelled.
    func pageFailed(code: Int, description: String)
    func pageAudible(_ audible: Bool)
    func pageFavicons(_ urls: [URL])
    /// The link under the pointer, nil when it leaves.
    func pageHover(_ link: URL?)
    func pageFullscreen(_ on: Bool)
    /// The page's process died.
    func pageProcessGone()
    /// A link asked for a tab of its own: ⌘-click, middle-click, a target.
    func pageWantsTab(_ url: URL, foreground: Bool)
    /// The page called window.close().
    func pageWantsClose()
    /// A download finished at `file`.
    func pageDownloaded(_ file: URL, from source: URL?)
    /// The page was clicked or scrolled, or took the keyboard.
    func pageTouched()
}

/// Where a Chromium page keeps its cookies and sign-ins — the counterpart of
/// a WKWebsiteDataStore.
enum ChromiumProfile: Hashable {
    /// Every tab's, unless spaces keep their own: Chromium's global context.
    /// Playwright sees these tabs in its default context.
    case main
    /// A space that keeps its own sign-ins.
    case space(UUID)
    /// In memory only, gone with its last tab. Tabs opened from a private
    /// tab share its key, as WebKit's share its store.
    case ephemeral(UUID)
}
