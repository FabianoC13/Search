import Foundation
#if os(macOS)
import AppKit
#else
import FoundationNetworking
import Glibc
#endif

// Search's DevTools bridge on its own, in front of Playwright's headless
// Chromium, with FakeSearch.swift playing the rest of Search: what
// `./playwright.sh bridge` runs Tests/Playwright's specs and safety.mjs
// through, with no Search built (see run.sh).
//
// Launch mode: Playwright starts this as it starts Chrome — a profile
// folder, DevTools on a pipe, its switches — and Launch.swift reads that as
// Search does. Attach mode: HARNESS_PORT=<port> on the command line, then
// connectOverCDP to that port.
//
// HARNESS_CHROME is the Chromium to run.

let environment = ProcessInfo.processInfo.environment
guard let chrome = environment["HARNESS_CHROME"] else {
    FileHandle.standardError.write(Data("HARNESS_CHROME: which Chromium to run (see run.sh)\n".utf8))
    exit(2)
}
let outer = Launch.active ? (Launch.port ?? 0) : Int(environment["HARNESS_PORT"] ?? "") ?? 9339
let inner = 20000 + Int(getpid() % 20000)
let profile = Launch.userDataDir?.path
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("search-bridge-\(getpid())").path
var given = ["--headless", "--no-sandbox", "--remote-debugging-port=\(inner)", "--user-data-dir=\(profile)"]
given += (Launch.active ? Launch.switches : PlaywrightSwitches.attach).map { "--" + $0 }
if Launch.noStartupWindow { given.append("--no-startup-window") }
if let start = Launch.startURL { given.append(start.absoluteString) }
if !Launch.active { given.append("about:blank") }

let chromium = Process()
chromium.executableURL = URL(fileURLWithPath: chrome)
chromium.arguments = given
chromium.standardOutput = FileHandle.nullDevice
chromium.standardError = environment["HARNESS_CHROME_LOG"] == nil ? FileHandle.nullDevice : FileHandle.standardError
try chromium.run()
nonisolated(unsafe) var child = chromium.processIdentifier
atexit { kill(child, SIGKILL) }
signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

#if os(Linux)
// Foundation's WebSockets and HTTP don't reach Chromium on Linux.
DevToolsNet.socket = { PosixSocket(url: $0) }
DevToolsNet.fetch = posixFetch
#endif

MainActor.assumeIsolated {
    DevToolsBridge.shared.start(outer: outer, inner: inner)
    if Launch.pipe { DevToolsBridge.shared.startPipe() }
    DevToolsBridge.shared.watcher.whenBrowserPath { path in
        Automation.shared.start(URL(string: "ws://127.0.0.1:\(inner)\(path)")!, yours: !Launch.active)
    }
}

#if os(macOS)
// The bridge quits through NSApp.terminate, as Search does.
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
#else
dispatchMain()
#endif
