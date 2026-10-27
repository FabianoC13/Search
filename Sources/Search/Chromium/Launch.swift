import Foundation

// Search started by Playwright itself: chromium.launch or
// launchPersistentContext with Search's executable, or Playwright's own test
// suite run against it (CRPATH). Playwright starts Chrome the same way every
// time — a profile folder of its own (--user-data-dir), DevTools on a pipe
// (--remote-debugging-pipe, file descriptors 3 and 4) or a port, and its own
// list of Chromium's switches — and Search answers in kind:
//
// - everything it keeps lives in that folder, never in yours, even with
//   your own Search open beside it (Store.folder, Store.settings);
// - it runs Chromium whatever the settings say, from the add-on you have
//   installed (ChromiumAddon.home);
// - the switches go to Chromium as given, except the ones Search answers
//   itself;
// - nothing of a first launch shows: no welcome, no What's New, no update
//   check, no session to bring back;
// - Browser.close, or the pipe closing, quits it at once.
//
// Anything else — a plain launch, or `--remote-debugging-port` alone — is an
// ordinary Search.

enum Launch {
    private static let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

    /// The value of `--name=value`, the last given.
    private static func value(_ name: String) -> String? {
        let prefix = "--\(name)="
        return arguments.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// DevTools on file descriptors 3 (in) and 4 (out), as Playwright
    /// always asks when it starts a browser itself.
    static let pipe = arguments.contains("--remote-debugging-pipe")

    /// The profile folder Playwright made for this run.
    static let userDataDir: URL? = {
        guard let path = value("user-data-dir"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }()

    /// Started by a tool: a profile folder of its own, and DevTools asked
    /// for with it.
    static let active = userDataDir != nil && (pipe || value("remote-debugging-port") != nil)

    /// The port asked for on the command line, in launch mode: 0 for any
    /// free one, as Playwright asks when it reads the address back.
    static let port: Int? = active ? value("remote-debugging-port").flatMap(Int.init) : nil

    /// Chromium's headless mode, which Search has no way to be.
    static let headless = active && arguments.contains { $0 == "--headless" || $0.hasPrefix("--headless=") }

    /// No window at the start: chromium.launch, whose pages all come in
    /// contexts of their own.
    static let noStartupWindow = active && arguments.contains("--no-startup-window")

    /// The page to open first: about:blank for launchPersistentContext. The
    /// last word on the command line that isn't a switch.
    static let startURL: URL? = {
        guard active, let last = arguments.last, !last.hasPrefix("-") else { return nil }
        return URL(string: last)
    }()

    /// What Search answers itself rather than Chromium: its profile, its
    /// DevTools, its windows, its sandbox.
    private static let own: [String] = [
        "user-data-dir", "remote-debugging-pipe", "remote-debugging-port", "headless", "no-startup-window",
        "no-sandbox",
    ]

    /// The switches meant for Chromium, as Playwright gave them, without
    /// their dashes.
    static let switches: [String] = {
        guard active else { return [] }
        return arguments.compactMap { argument in
            guard argument.hasPrefix("--") else { return nil }
            let body = String(argument.dropFirst(2))
            let name = body.split(separator: "=", maxSplits: 1).first.map(String.init) ?? body
            return own.contains(name) || name.isEmpty ? nil : body
        }
    }()

    /// Said on stderr, where Playwright collects what a browser says when
    /// it fails to start, and then gone.
    static func refuseHeadless() {
        guard headless else { return }
        let line = "Search runs headed only: launch it with headless: false.\n"
        FileHandle.standardError.write(Data(line.utf8))
        exit(1)
    }
}
