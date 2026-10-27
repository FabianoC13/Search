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
    /// Its DevTools target and browser context, as tools name them, once
    /// the page has said (see Automation).
    private(set) var targetID: String?
    private(set) var contextID: String?

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

    /// A page for a popup another page opens (PageEventSink.pageWantsPopup):
    /// Chromium makes its browser itself, with the opener's profile, so it
    /// keeps its opener, the POST body it was opened with and the rest.
    init(popupOf profile: ChromiumProfile, sink: PageEventSink) {
        self.sink = sink
        let relay = Unmanaged.passRetained(Relay(page: self, profile: profile))
        var events = ChromiumPage.events
        events.context = relay.toOpaque()
        // Held as a page made in it would hold it, let go of by `closed`.
        _ = ChromiumRuntime.context(for: profile)
        let holder = Unmanaged.passUnretained(view).toOpaque()
        page = chromium_page_make_popup(holder, &events)
        if page == nil {
            relay.release()
            ChromiumRuntime.release(profile)
        }
    }

    /// The C layer's page, for the popup event to hand back.
    var handle: OpaquePointer? { page }

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
        // Out of the room a tool's pages run in (see Automation), and gone.
        if view.window === Automation.shared.room { view.removeFromSuperview() }
        guard let page else { return }
        self.page = nil
        chromium_page_close(page)
    }

    // MARK: - Questions

    /// The page's question answered: OK or not, and a prompt's text.
    func answer(ok: Bool, text: String?) {
        guard let page else { return }
        if let text {
            text.withCString { chromium_page_answer(page, ok ? 1 : 0, $0) }
        } else {
            chromium_page_answer(page, ok ? 1 : 0, nil)
        }
    }

    /// The question was answered elsewhere: let go of without an answer.
    func forgetQuestion() {
        if let page { chromium_page_forget_question(page) }
    }

    /// The permission the page asked for, answered (see
    /// PageEventSink.pagePermission).
    func permit(media: Bool, granted: Bool) {
        if let page { chromium_page_permit(page, media ? 1 : 0, granted ? 1 : 0) }
    }

    // MARK: - For tools (see Automation)

    /// The size a tool set (Emulation.setDeviceMetricsOverride): the page
    /// laid out at exactly that, at the top left of its tab, as Chrome's
    /// window is sized to it. Nil: the tab's own size.
    var viewport: NSSize? {
        get { (view as? Holder)?.fixed }
        set { (view as? Holder)?.fixed = newValue }
    }

    /// The tool's mouse, drawn over the page: `point` in the page's CSS
    /// pixels from its top left.
    func showPointer(at point: CGPoint, pressed: Bool) {
        (view as? Holder)?.point(at: point, pressed: pressed)
    }

    func hidePointer() {
        (view as? Holder)?.hidePointer()
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
        events.target = { context, target, browserContext, browser in
            guard let target else { return }
            let id = String(cString: target)
            let contextID = browserContext.map { String(cString: $0) } ?? ""
            Relay.page(context) { page in
                page.targetID = id
                page.contextID = contextID
                page.sink?.pageTarget(id, context: contextID, browser: browser)
            }
        }
        events.dialog = { context, kind, origin, message, text, reload in
            let from = origin.map { String(cString: $0) } ?? ""
            let said = message.map { String(cString: $0) } ?? ""
            let given = text.map { String(cString: $0) } ?? ""
            return Relay.answer(context, otherwise: 0) { page -> Int32 in
                page.sink?.pageAsks(Int(kind), origin: from, message: said, text: given, reload: reload != 0) == true ? 1 : 0
            }
        }
        events.dialog_gone = { context in
            Relay.page(context) { $0.sink?.pageQuestionGone() }
        }
        events.popup = { context, url, kind, _ in
            let address = url.map { String(cString: $0) } ?? ""
            let made = Relay.pointer(context) { page -> Int in
                let link = address.isEmpty ? nil : URL(string: address)
                return Int(bitPattern: page.sink?.pageWantsPopup(link, kind: Int(kind))?.handle)
            }
            return OpaquePointer(bitPattern: made)
        }
        events.permission = { context, origin, media, kinds in
            let from = origin.map { String(cString: $0) } ?? ""
            return Relay.answer(context, otherwise: -1) { page -> Int32 in
                page.sink?.pagePermission(origin: from, media: media != 0, kinds: UInt32(kinds)) ?? -1
            }
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

    /// The same, for a callback the C layer waits on for an answer:
    /// `otherwise` when the page has gone.
    static func answer(_ context: UnsafeMutableRawPointer?, otherwise: Int32,
                       _ body: @MainActor (ChromiumPage) -> Int32) -> Int32 {
        guard let context else { return otherwise }
        let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard let page = relay.page else { return otherwise }
            return body(page)
        }
    }

    /// The same, for a page handed back across the C boundary as its bits.
    static func pointer(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (ChromiumPage) -> Int) -> Int {
        let otherwise = 0
        guard let context else { return otherwise }
        let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard let page = relay.page else { return otherwise }
            return body(page)
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
        // A page laid out larger than its tab (a tool's viewport) stays
        // inside it.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// A size a tool set for the page, at the top left; nil to fill.
    var fixed: NSSize? {
        didSet {
            guard fixed != oldValue else { return }
            resizeSubviews(withOldSize: bounds.size)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews {
            if view === arrow {
                view.frame = bounds
            } else if let fixed {
                view.frame = NSRect(x: 0, y: bounds.height - fixed.height, width: fixed.width, height: fixed.height)
            } else {
                view.frame = bounds
            }
        }
    }

    // MARK: The tool's pointer

    private var arrow: PointerView?

    /// `point` in CSS pixels from the page's top left: the same as points
    /// at 100% zoom, which a page a tool drives is held at.
    func point(at point: CGPoint, pressed: Bool) {
        let view = arrow ?? {
            let made = PointerView(frame: bounds)
            arrow = made
            return made
        }()
        // Over Chromium's view, which came in after it was made.
        if subviews.last !== view {
            view.removeFromSuperview()
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        view.frame = bounds
        // The page's top left is the holder's, whatever size it is laid
        // out at (see resizeSubviews).
        view.move(to: CGPoint(x: point.x, y: bounds.height - point.y), pressed: pressed)
    }

    func hidePointer() {
        arrow?.removeFromSuperview()
        arrow = nil
    }
}

/// The arrow drawn where a tool's mouse is, with a ring that spreads from
/// it when it presses. Never in the way: clicks go through it to the page.
private final class PointerView: NSView {
    private let shape = CAShapeLayer()
    private var fade: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let path = CGMutablePath()
        // The arrow of the system's own cursor, its tip at the origin.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: -17))
        path.addLine(to: CGPoint(x: 4.2, y: -13))
        path.addLine(to: CGPoint(x: 7, y: -19.5))
        path.addLine(to: CGPoint(x: 9.8, y: -18.3))
        path.addLine(to: CGPoint(x: 7.1, y: -12))
        path.addLine(to: CGPoint(x: 12.5, y: -12))
        path.closeSubpath()
        shape.path = path
        shape.fillColor = NSColor.black.cgColor
        shape.strokeColor = NSColor.white.cgColor
        shape.lineWidth = 1.4
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 2
        shape.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        fatalError("not made from a nib")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func move(to point: CGPoint, pressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.position = point
        shape.opacity = 1
        CATransaction.commit()
        if pressed { ripple(at: point) }
        fade?.cancel()
        let later = DispatchWorkItem { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            self.shape.opacity = 0
            CATransaction.commit()
        }
        fade = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: later)
    }

    private func ripple(at point: CGPoint) {
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -6, y: -6, width: 12, height: 12), transform: nil)
        ring.position = point
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 1.5
        layer?.insertSublayer(ring, below: shape)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 3.2
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1
        vanish.toValue = 0
        ring.add(grow, forKey: "grow")
        ring.add(vanish, forKey: "vanish")
        ring.opacity = 0
        CATransaction.commit()
    }
}
