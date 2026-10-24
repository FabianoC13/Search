import AppKit

// CONTRACT STUB — replaced by the Chromium layer. Signatures are fixed:
// the rest of the app is written against them.

/// Chromium for this process: found, loaded, started, pumped, shut down.
@MainActor
enum ChromiumRuntime {
    enum Start {
        case started
        /// Why not, in words for Settings.
        case failed(String)
    }

    /// Loads the add-on and starts Chromium. Called once, by
    /// WebEngine.current, on the main thread.
    static func start() -> Start {
        .failed("Chromium isn't installed.")
    }

    /// The port Playwright and other DevTools clients connect to, 0 when
    /// automation is off. Fixed at start.
    static var debuggingPort: Int { 0 }

    /// Closes every page and stops Chromium. Called once, as the app quits,
    /// after the session is saved.
    static func shutdown() {}
}

/// The add-on: Chromium's framework and its helper apps, kept in
/// Store.folder/Chromium/<version>/, outside the app, so Search stays small
/// for everyone who never turns Chromium on.
@MainActor
final class ChromiumAddon: ObservableObject {
    static let shared = ChromiumAddon()

    enum State: Equatable {
        case absent
        /// Not offered by the feed yet, and nothing installed.
        case unavailable
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .absent
    /// The download's size in bytes when the feed offers one.
    var size: Int64? { nil }
    /// The Chromium version installed, or offered.
    var version: String? { nil }

    func install() {}
    func cancel() {}
    func remove() {}
}

/// A tab's page drawn by Chromium.
@MainActor
final class ChromiumPage: PageEngine {
    let view = NSView()
    private(set) var url: URL?
    private(set) var isLoading = false
    var backItemURL: URL? { nil }
    var pageZoom: CGFloat = 1

    /// `url` is loaded as soon as the page exists; nil leaves it blank.
    init(url: URL?, profile: ChromiumProfile, sink: PageEventSink) {
        self.url = url
    }

    func open(_ url: URL) {}
    func reload(fromOrigin: Bool) {}
    func stopLoading() {}
    func goBack() {}
    func goForward() {}
    func setMuted(_ muted: Bool) {}
    func evaluate(_ script: String, then: ((Any?) -> Void)?) { then?(nil) }
    func snapshot(width: CGFloat?, _ done: @escaping (NSImage?) -> Void) { done(nil) }
    var restorableState: Any? { nil }
    func restore(_ state: Any) {}
    func showInspector() {}
    func printPage() {}
    func tearDown() {}
}
