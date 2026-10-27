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

        // Who drives it. Tools you let in (Settings › Engine, or
        // --remote-debugging-port): Search listens on the port asked for (see
        // DevToolsBridge). Or Playwright, which started Search for a run
        // (Launch.swift): a pipe, or a port it named. Chromium's own server
        // goes on a port nothing else has, which only the bridge talks to.
        var inner = 0
        if Launch.active {
            inner = freePort()
            port = Launch.port.map { $0 > 0 ? $0 : freePort() } ?? 0
        } else {
            port = requested()
            inner = port > 0 ? freePort() : 0
        }
        // Playwright's switches: as it gave them in launch mode; with your own
        // profile, only those that touch nothing of yours (PlaywrightSwitches).
        let switches = Launch.active ? Launch.switches : port > 0 ? PlaywrightSwitches.attach : []
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
        let name = Store.beta ? "Search Beta Chromium" : "Search Chromium"
        options.keychain_service = text("\(name) Safe Storage")
        options.keychain_account = text(name)
        // Chromium's own server, which only the bridge talks to: the port
        // asked for is the bridge's, so a tool's new pages are Search's tabs.
        options.port = Int32(inner)
        options.mock_keychain = Store.testing ? 1 : 0
        let given: [UnsafePointer<CChar>?] = switches.map { text($0) }
        let started = given.withUnsafeBufferPointer { list -> Int32 in
            options.switches = list.baseAddress
            options.switch_count = Int32(list.count)
            return chromium_start(&options, &error, error.count)
        }
        guard started == 1 else {
            Store.settings.removeObject(forKey: WebEngine.startingKey)
            port = 0
            return .failed(String(cString: error))
        }
        running = true
        if inner > 0 {
            DevToolsBridge.shared.start(outer: port, inner: inner)
            if Launch.pipe { DevToolsBridge.shared.startPipe() }
        }
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

    /// A port nothing on this Mac listens on, as the system hands one out.
    static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 0 }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { named in
                Darwin.bind(socket, named, length) == 0 && getsockname(socket, named, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 0
    }

    /// A proxy for every page of a tool's context (Target.createBrowserContext).
    static func setProxy(_ server: String, bypass: String?, for profile: ChromiumProfile) {
        guard let context = context(for: profile) else { return }
        _ = server.withCString { serverText in
            if let bypass {
                return bypass.withCString { chromium_context_set_proxy(context, serverText, $0) }
            }
            return chromium_context_set_proxy(context, serverText, nil)
        }
        // Held for its pages to come; let go of as a page of it is.
        release(profile)
    }

    /// What a tool granted an origin in a context of its own
    /// (Automation.grant), kept as the site's settings there; nil puts them
    /// back to the default.
    static func setPermissions(_ names: [String]?, origin: String, for profile: ChromiumProfile) {
        guard let context = context(for: profile) else { return }
        defer { release(profile) }
        guard let names else { return chromium_context_set_permissions(context, origin, nil, 0) }
        let copies = names.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { $0.map { UnsafePointer($0) } }
        pointers.withUnsafeBufferPointer { chromium_context_set_permissions(context, origin, $0.baseAddress, Int32($0.count)) }
    }

    /// The port asked for: only one nothing system-wide needs, and only on
    /// 127.0.0.1.
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
