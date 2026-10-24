import SwiftUI

/// Settings › Engine: which engine draws pages, Chromium's add-on, and
/// whether tools may drive Chromium. Picking the other engine changes
/// nothing until Search relaunches into it: the engine is chosen once, at
/// launch (see PageEngine.swift), so the switch is a button, not the picker.
struct EngineSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var addon = ChromiumAddon.shared

    /// The engine picked here; the one running until the relaunch.
    @State private var pending = WebEngine.current
    /// Told to stay with WebKit after Chromium didn't start.
    @State private var settled = false
    @State private var drives = Store.settings.integer(forKey: WebEngine.portKey) != 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Web engine", "What draws the pages. Search looks and works the same around them") {
                    Segmented(options: WebEngine.allCases.map { ($0, $0.title) }, selection: $pending)
                }
                if pending != WebEngine.current {
                    Rule()
                    switching
                }
                if let fallback = WebEngine.fallback, !settled {
                    Rule()
                    Line("Opened with WebKit", fallback) {
                        // Still chosen, Chromium is tried again at every launch
                        // until it is told otherwise.
                        if WebEngine.chosen == .chromium {
                            Pill("Stay with WebKit") {
                                Store.settings.set(WebEngine.webkit.rawValue, forKey: WebEngine.key)
                                settled = true
                            }
                        }
                    }
                }
                Rule()
                Line("What Chromium leaves out", "For now: extensions, saving and filling passwords, passkeys, hiding things, the ad blocker, reading mode, the floating video, AI, find on the page and site notifications") {
                    EmptyView()
                }
                Rule()
                Line("Sign-ins", "Each engine keeps its own: switching means signing in to sites again. Tabs, history, bookmarks and passwords are the same in both") {
                    EmptyView()
                }
            }
            Card {
                Line("Let Playwright and other tools drive Chromium", portDetail) {
                    Switch(on: $drives)
                }
                if addon.state == .ready, WebEngine.current != .chromium {
                    Rule()
                    Line("Chromium add-on", installedDetail) {
                        Pill("Remove") { addon.remove() }
                    }
                }
            }
        }
        .onChange(of: drives) { _, on in
            Store.settings.set(on ? WebEngine.port : 0, forKey: WebEngine.portKey)
        }
    }

    /// The way to the engine picked: a relaunch when it is there to switch
    /// to, Chromium's add-on on its way otherwise.
    @ViewBuilder
    private var switching: some View {
        if pending == .webkit {
            Line("Switch to WebKit", "Search quits and opens again with your tabs, drawn by WebKit") {
                Pill("Switch and relaunch", filled: true) { WebEngine.relaunch(into: .webkit) }
            }
        } else {
            switch addon.state {
            case .unavailable:
                Line("Chromium isn't offered yet", "An update to Search will bring it, to download here") { EmptyView() }
            case .absent:
                Line("Chromium", "Downloaded once\(sizeNote) and checked, and kept beside Search rather than in it, so Search stays small for everyone who never turns it on") {
                    Pill(size.map { "Download (\($0))" } ?? "Download", filled: true) { addon.install() }
                }
            case .downloading(let done):
                Line("Chromium", "Downloading… \(Int(done * 100))%") {
                    Pill("Cancel") { addon.cancel() }
                }
            case .installing:
                Line("Chromium", "Checking it and putting it in place") { Ring(size: 12) }
            case .ready:
                Line("Switch to Chromium", "Search quits and opens again with your tabs, drawn by Chromium") {
                    Pill("Switch and relaunch", filled: true) { WebEngine.relaunch(into: .chromium) }
                }
            case .failed(let why):
                Line("Chromium", why) {
                    Pill("Try Again") { addon.install() }
                }
            }
        }
    }

    private var size: String? {
        addon.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private var sizeNote: String { size.map { " (\($0))" } ?? "" }

    private var installedDetail: String {
        let version = addon.version.map { "Chromium \($0)" } ?? "Chromium"
        return "\(version), on this Mac for when you switch. Removing it takes it off; it can be downloaded again"
    }

    /// What the switch means: listening now, or from the next launch that
    /// runs Chromium, since the port is fixed as Chromium starts.
    private var portDetail: String {
        let port = ChromiumRuntime.debuggingPort
        if WebEngine.current == .chromium, port > 0 {
            return drives
                ? "Listening on 127.0.0.1:\(port), for chromium.connectOverCDP. Only on this Mac"
                : "Listening on 127.0.0.1:\(port) until Search next opens"
        }
        let when = WebEngine.current == .chromium ? "from the next launch" : "when Search runs Chromium"
        return "DevTools on 127.0.0.1:\(WebEngine.port) \(when), for Playwright's chromium.connectOverCDP. Anything on this Mac can then drive the browser"
    }
}
