import AppKit

// The app's side of the engine switch (see PageEngine.swift): the one test
// every WebKit-only path asks before it reaches for WebKit, and the switch
// itself, which Settings › Engine and the Search menu both make.

extension WebEngine {
    /// True when this process draws its pages with WebKit. Everything only
    /// WebKit has — its stores, its extension controller, its content
    /// blocker, the scripts it runs in a page — asks this first: in
    /// Chromium mode none of it may be made, not even to do nothing.
    @MainActor static var isWebKit: Bool { current == .webkit }

    /// Settings: the port Chromium's DevTools listen on at the next launch,
    /// for Playwright and other tools, or 0 for none.
    nonisolated static let portKey = "chromium.debuggingPort"
    /// The port asked for when tools may drive Chromium: the one
    /// Playwright's examples and Chrome's own flag use.
    nonisolated static let port = 9222

    /// Whether `engine` can be switched to now: WebKit always can, Chromium
    /// once its add-on is installed.
    @MainActor static func ready(_ engine: WebEngine) -> Bool {
        engine == .webkit || ChromiumAddon.shared.state == .ready
    }

    /// Saves the choice and relaunches into it. Quitting saves the session
    /// as ⌘Q does, and the launch that follows keeps it even with "Start
    /// with a fresh window" on (see SearchApp.init): a switch is not a
    /// fresh start.
    @MainActor static func relaunch(into engine: WebEngine) {
        Store.settings.set(engine.rawValue, forKey: key)
        Store.settings.set(true, forKey: switchingKey)
        Updater.shared.relaunch()
    }

    /// The other engine, for the menu's Switch to … item.
    var other: WebEngine { self == .webkit ? .chromium : .webkit }
}
