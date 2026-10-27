import AppKit
import CChromium

// Chromium in this process: found, loaded, started, pumped, shut down. The
// work is the C layer's (Sources/CChromium); this is where Search's side of
// it is decided — which add-on, which profile, which port.
//
// Everything Chromium keeps lives in Store.folder/Chromium/Profile, apart
// from the add-on's versioned folder, so updating Chromium keeps the
// sign-ins, and a test world keeps its own. The tabs' profile is
// Profile/Default; a space that keeps its own sign-ins gets one beside it,
// Profile/Space-<id> (Chrome takes only profiles directly inside its
// folder, and quietly uses another for anything deeper); private tabs get
// one in memory.

/// Chromium for this process: found, loaded, started, pumped, shut down.
@MainActor
enum ChromiumRuntime {
    enum Start {
        case started
        /// Why not, in words for Settings.
        case failed(String)
    }

    /// The setting for remote debugging: the port, 0 or absent for none.
    /// Settings writes it, behind the same consent as letting a script
    /// drive Search; `--remote-debugging-port=N` at launch does the same.
    nonisolated static let portKey = "chromium.debuggingPort"

    /// Started in this process and not yet shut down.
    private(set) static var running = false
    private static var port = 0
    private static var settled = false

    private static var profile: URL {
        ChromiumAddon.folder.appendingPathComponent("Profile", isDirectory: true)
    }

    /// Loads the add-on and starts Chromium. Called once, by
    /// WebEngine.current, on the main thread.
    static func start() -> Start {
        if running { return .started }
        guard let home = ChromiumAddon.shared.installed else { return .failed("Chromium isn't installed.") }
        if let why = ChromiumAddon.trust(home) { return .failed(why) }

        let files = FileManager.default
        // Chromium checks that each profile is inside the root by its path
        // as written, so neither may go through a symbolic link.
        let root = profile.resolvingSymlinksInPath()
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("Default", isDirectory: true)
        let log = ChromiumAddon.folder.appendingPathComponent("chromium.log")

        // From here until the first page is up, a crash is Chromium's: the
        // next launch sees the mark and runs WebKit instead.
        Store.settings.set(true, forKey: WebEngine.startingKey)
        var error = [CChar](repeating: 0, count: 512)
        guard chromium_load(ChromiumAddon.binary(in: home).path, &error, error.count) == 1 else {
            Store.settings.removeObject(forKey: WebEngine.startingKey)
            return .failed(String(cString: error))
        }

        port = requested()
        var kept: [UnsafeMutablePointer<CChar>] = []
        defer { kept.forEach { free($0) } }
        func text(_ string: String?) -> UnsafePointer<CChar>? {
            guard let string, let copy = strdup(string) else { return nil }
            kept.append(copy)
            return UnsafePointer(copy)
        }
        var options = chromium_options()
        options.framework = text(ChromiumAddon.framework(in: home).path)
        options.helper = text(ChromiumAddon.helper(in: home).path)
        options.bundle = text(Bundle.main.bundlePath)
        options.root = text(root.path)
        options.cache = text(cache.path)
        options.log = text(log.path)
        options.locale = text(Locale.preferredLanguages.first)
        // A key of Search's own for cookies' encryption, not Chrome's: no
        // keychain prompt naming another app. A test run keeps it in memory,
        // since a build signed ad hoc is a stranger to the keychain each time.
        options.keychain_service = text("Search Chromium Safe Storage")
        options.keychain_account = text("Search Chromium")
        // Chromium's own server is one port up; the port asked for is the
        // bridge's (DevToolsBridge), so a tool's new pages are Search's tabs.
        options.port = Int32(port > 0 ? port + 1 : 0)
        options.mock_keychain = Store.testing ? 1 : 0
        guard chromium_start(&options, &error, error.count) == 1 else {
            Store.settings.removeObject(forKey: WebEngine.startingKey)
            port = 0
            return .failed(String(cString: error))
        }
        running = true
        if port > 0 { DevToolsBridge.shared.start(outer: port, inner: port + 1) }
        // A launch with no page to show still counts as started once it has
        // run a while without falling over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { settle() }
        return .started
    }

    /// The port Playwright and other DevTools clients connect to, 0 when
    /// automation is off. Fixed at start.
    static var debuggingPort: Int { running ? port : 0 }

    /// Closes every page and stops Chromium. Called once, as the app quits,
    /// after the session is saved.
    static func shutdown() {
        guard running else { return }
        running = false
        chromium_stop(2)
        // Chromium has let go of them; only their wrappers are left.
        spaces.values.forEach { chromium_context_drop($0) }
        ephemeral.values.forEach { chromium_context_drop($0.context) }
        spaces.removeAll()
        ephemeral.removeAll()
    }

    /// The first page is up: Chromium started. Called by ChromiumPage.
    static func settle() {
        guard !settled else { return }
        settled = true
        Store.settings.removeObject(forKey: WebEngine.startingKey)
    }

    /// Only ports nothing system-wide needs, and only on 127.0.0.1, which
    /// is all Chromium listens on. Chromium takes the one above it.
    private static func requested() -> Int {
        let flag = "--remote-debugging-port="
        let asked = ProcessInfo.processInfo.arguments.last { $0.hasPrefix(flag) }
            .flatMap { Int($0.dropFirst(flag.count)) } ?? Store.settings.integer(forKey: portKey)
        return (1024...65534).contains(asked) ? asked : 0
    }

    // MARK: - Profiles

    private static var spaces: [UUID: OpaquePointer] = [:]
    private static var ephemeral: [UUID: (context: OpaquePointer, pages: Int)] = [:]

    /// Where a page of `profile` keeps its cookies, held for one more page
    /// until `release`. Nil when Chromium isn't running.
    static func context(for profile: ChromiumProfile) -> OpaquePointer? {
        guard running else { return nil }
        switch profile {
        case .main:
            return chromium_context_global()
        case .space(let id):
            if let made = spaces[id] { return made }
            let folder = self.profile.resolvingSymlinksInPath()
                .appendingPathComponent("Space-\(id.uuidString)", isDirectory: true)
            guard let made = chromium_context_make(folder.path) else { return nil }
            spaces[id] = made
            return made
        case .ephemeral(let id):
            if var entry = ephemeral[id] {
                entry.pages += 1
                ephemeral[id] = entry
                return entry.context
            }
            guard let made = chromium_context_make(nil) else { return nil }
            ephemeral[id] = (made, 1)
            return made
        }
    }

    /// A page of `profile` has gone. A private one's memory goes with its
    /// last page.
    static func release(_ profile: ChromiumProfile) {
        guard case .ephemeral(let id) = profile, var entry = ephemeral[id] else { return }
        entry.pages -= 1
        if entry.pages > 0 {
            ephemeral[id] = entry
            return
        }
        ephemeral[id] = nil
        chromium_context_drop(entry.context)
    }
}
