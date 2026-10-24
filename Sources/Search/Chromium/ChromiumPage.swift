import AppKit
import CChromium

// A tab's page, drawn by Chromium. The page is a plain view the stage puts
// in the window; Chromium's own view sits inside it, filling it, and goes
// with it from window to window without reloading.
//
// What the page does comes back through the C layer's callbacks, to a
// relay that holds the page weakly: a page dropped without tearDown is
// closed as it goes, and Chromium's last word (`closed`) still finds the
// relay, which lets go of the page's profile and then of itself.

/// A tab's page drawn by Chromium.
@MainActor
final class ChromiumPage: PageEngine {
    let view: NSView = Holder()
    private(set) var url: URL?
    private(set) var isLoading = false
    private weak var sink: PageEventSink?
    /// The C layer's page, until it is closed.
    private var page: OpaquePointer?
    /// Asked for before the page could take it, or with no page at all.
    private var zoom: CGFloat = 1

    /// `url` is loaded as soon as the page exists; nil leaves it blank.
    init(url: URL?, profile: ChromiumProfile, sink: PageEventSink) {
        self.url = url
        self.sink = sink
        let relay = Unmanaged.passRetained(Relay(page: self, profile: profile))
        var events = ChromiumPage.events
        events.context = relay.toOpaque()
        let context = ChromiumRuntime.context(for: profile)
        let holder = Unmanaged.passUnretained(view).toOpaque()
        if let address = url?.absoluteString {
            page = address.withCString { chromium_page_make(holder, $0, context, &events) }
        } else {
            page = chromium_page_make(holder, nil, context, &events)
        }
        // No page, no `closed` to come: let go now.
        if page == nil {
            relay.release()
            ChromiumRuntime.release(profile)
        }
    }

    deinit {
        if let page { chromium_page_close(page) }
    }

    var backItemURL: URL? {
        guard let page, let text = chromium_page_back_url(page) else { return nil }
        defer { free(text) }
        return URL(string: String(cString: text))
    }

    /// Chromium counts zoom in levels, each 20% more than the last: 100% is
    /// level 0, 120% level 1.
    var pageZoom: CGFloat {
        get {
            guard let page else { return zoom }
            return CGFloat(pow(1.2, chromium_page_zoom(page)))
        }
        set {
            zoom = max(0.25, min(5, newValue))
            if let page { chromium_page_set_zoom(page, log(Double(zoom)) / log(1.2)) }
        }
    }

    func open(_ url: URL) {
        guard let page else { return }
        url.absoluteString.withCString { chromium_page_open(page, $0) }
    }

    func reload(fromOrigin: Bool) {
        if let page { chromium_page_reload(page, fromOrigin ? 1 : 0) }
    }

    func stopLoading() {
        if let page { chromium_page_stop(page) }
    }

    func goBack() {
        if let page { chromium_page_back(page) }
    }

    func goForward() {
        if let page { chromium_page_forward(page) }
    }

    func setMuted(_ muted: Bool) {
        if let page { chromium_page_set_muted(page, muted ? 1 : 0) }
    }

    /// Chromium runs it and keeps the result to itself.
    func evaluate(_ script: String, then: ((Any?) -> Void)?) {
        if let page { script.withCString { chromium_page_run(page, $0) } }
        then?(nil)
    }

    func snapshot(width: CGFloat?, _ done: @escaping (NSImage?) -> Void) { done(nil) }
    var restorableState: Any? { nil }
    func restore(_ state: Any) {}

    func showInspector() {
        if let page { chromium_page_inspect(page) }
    }

    func printPage() {
        if let page { chromium_page_print(page) }
    }

    /// Gives the page the keyboard.
    func focus() {
        if let page { chromium_page_focus(page) }
    }

    func tearDown() {
        sink = nil
        guard let page else { return }
        self.page = nil
        chromium_page_close(page)
    }

    // MARK: - What the page reports

    /// A net error (net_error_list.h) as the NSURLError code a tab already
    /// knows how to explain.
    nonisolated static func urlError(_ net: Int) -> Int {
        switch net {
        case -105, -137: return NSURLErrorCannotFindHost
        case -106: return NSURLErrorNotConnectedToInternet
        case -102: return NSURLErrorCannotConnectToHost
        case -7, -118: return NSURLErrorTimedOut
        case -299 ... -200: return NSURLErrorSecureConnectionFailed
        default: return NSURLErrorUnknown
        }
    }

    private static func link(_ text: UnsafePointer<CChar>?) -> URL? {
        guard let text else { return nil }
        return URL(string: String(cString: text))
    }

    /// The callbacks, the same for every page; each finds its page through
    /// the context.
    private static let events: chromium_events = {
        var events = chromium_events()
        events.created = { context in
            Relay.page(context) { _ in ChromiumRuntime.settle() }
        }
        events.title = { context, title in
            let text = title.map { String(cString: $0) } ?? ""
            Relay.page(context) { $0.sink?.pageTitle(text) }
        }
        events.address = { context, address in
            guard let url = ChromiumPage.link(address) else { return }
            Relay.page(context) { page in
                page.url = url
                page.sink?.pageURL(url)
            }
        }
        events.progress = { context, progress in
            Relay.page(context) { $0.sink?.pageProgress(progress) }
        }
        events.loading = { context, loading, back, forward in
            Relay.page(context) { page in
                page.isLoading = loading != 0
                page.sink?.pageLoading(loading != 0, canGoBack: back != 0, canGoForward: forward != 0)
            }
        }
        events.committed = { context in
            Relay.page(context) { $0.sink?.pageCommitted() }
        }
        events.finished = { context, _ in
            Relay.page(context) { $0.sink?.pageFinished() }
        }
        events.failed = { context, code, text, _ in
            let description = text.map { String(cString: $0) } ?? ""
            Relay.page(context) { $0.sink?.pageFailed(code: ChromiumPage.urlError(Int(code)), description: description) }
        }
        events.icons = { context, urls, count in
            let icons = (0..<Int(count)).compactMap { ChromiumPage.link(urls?[$0]) }
            Relay.page(context) { $0.sink?.pageFavicons(icons) }
        }
        events.hover = { context, address in
            let url = ChromiumPage.link(address)
            Relay.page(context) { $0.sink?.pageHover(url) }
        }
        events.fullscreen = { context, on in
            Relay.page(context) { $0.sink?.pageFullscreen(on != 0) }
        }
        events.gone = { context, _ in
            Relay.page(context) { $0.sink?.pageProcessGone() }
        }
        events.tab = { context, address, foreground in
            guard let url = ChromiumPage.link(address) else { return }
            Relay.page(context) { $0.sink?.pageWantsTab(url, foreground: foreground != 0) }
        }
        events.close = { context in
            Relay.page(context) { $0.sink?.pageWantsClose() }
        }
        events.audible = { context, on in
            Relay.page(context) { $0.sink?.pageAudible(on != 0) }
        }
        events.downloaded = { context, file, source in
            guard let file else { return }
            let saved = URL(fileURLWithPath: String(cString: file))
            let from = ChromiumPage.link(source)
            Relay.page(context) { $0.sink?.pageDownloaded(saved, from: from) }
        }
        events.touched = { context in
            Relay.page(context) { $0.sink?.pageTouched() }
        }
        events.closed = { context in
            guard let context else { return }
            let relay = Unmanaged<Relay>.fromOpaque(context)
            MainActor.assumeIsolated {
                let held = relay.takeUnretainedValue()
                held.page?.page = nil
                ChromiumRuntime.release(held.profile)
            }
            relay.release()
        }
        return events
    }()
}

/// Between a page's callbacks and the page: there for as long as the C
/// layer's page is, which can be longer than the page itself.
private final class Relay {
    weak var page: ChromiumPage?
    let profile: ChromiumProfile

    init(page: ChromiumPage, profile: ChromiumProfile) {
        self.page = page
        self.profile = profile
    }

    /// Runs `body` with the page, if it is still there. Every callback
    /// arrives on the main thread.
    static func page(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (ChromiumPage) -> Void) {
        guard let context else { return }
        let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            if let page = relay.page { body(page) }
        }
    }
}

/// The page's place in the window. Chromium's view fills it, kept so here
/// as well as by its autoresizing, and the window's ground shows until the
/// first frame is painted.
private final class Holder: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}
