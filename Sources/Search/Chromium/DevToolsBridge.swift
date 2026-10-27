import AppKit
import CryptoKit
import Network

// What Playwright and other DevTools clients reach: Search's port (or, when
// Playwright started Search, its pipe — see Launch.swift), with Chromium's
// own DevTools server behind it on a port only this talks to. Everything
// passes through, so a tool drives Chromium as it drives Chrome, except
// where a tool would otherwise see Chromium's bare insides instead of
// Search, or reach what isn't its to reach:
//
// - Target.createTarget opens a real Search tab, in a window of the tool's
//   own (or of its context's), and answers once the tool has been told of
//   the page, as Chrome answers;
// - Target.createBrowserContext makes a private window of Search's (see
//   Automation), and the commands Chromium would refuse for it — downloads,
//   cookies, permissions — are answered by Search;
// - private tabs, and spaces that keep their own sign-ins, are never shown
//   to a tool, in any list or event;
// - a tool attached to your own Search can't close it or crash it;
// - what tells Search's side what to do — a page's viewport, the tool's
//   mouse, a dialog answered, a page brought to the front, a download — is
//   read on the way past (Automation).
//
// Only 127.0.0.1. A request whose Host isn't a loopback name is refused, so
// a web page can't reach this through DNS rebinding; so is a WebSocket a
// web page opens (it says where it comes from, as tools don't), as Chrome
// refuses them.

// MARK: - Talking to Chromium

/// One WebSocket to Chromium's own server: URLSession's on the Mac. A test
/// of the bridge away from the Mac puts its own in DevToolsNet.
protocol DevToolsSocket: AnyObject {
    /// One message.
    func send(_ text: String)
    /// The next message, or what ended the connection; on any thread.
    func receive(_ then: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

/// How the bridge reaches Chromium's server.
enum DevToolsNet {
    nonisolated(unsafe) static var socket: (URL) -> DevToolsSocket = { URLSessionSocket(url: $0) }
    /// An HTTP request's status and body; on any thread.
    nonisolated(unsafe) static var fetch: (URLRequest, @escaping (Int, Data?) -> Void) -> Void = { request, done in
        URLSession.shared.dataTask(with: request) { data, response, _ in
            done((response as? HTTPURLResponse)?.statusCode ?? 502, data)
        }.resume()
    }
}

private final class URLSessionSocket: DevToolsSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 256 << 20
        task.resume()
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    func receive(_ then: @escaping (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .success(.string(let text)): then(.success(text))
            case .success(.data(let data)): then(.success(String(decoding: data, as: UTF8.self)))
            case .failure(let error): then(.failure(error))
            @unknown default: then(.success(""))
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

@MainActor
final class DevToolsBridge {
    static let shared = DevToolsBridge()

    private var listener: NWListener?
    /// The port tools reach, 0 for none (the pipe only); Chromium's own.
    private(set) var outer = 0
    private(set) var inner = 0
    let watcher = TargetWatcher()
    /// Every tool connected now.
    private var sessions: [ObjectIdentifier: ToolSession] = [:]
    private var pipe: PipeLink?

    /// Starts listening on `outer` (if any) for a Chromium whose own server
    /// is on `inner`. Once a run.
    func start(outer: Int, inner: Int) {
        guard self.inner == 0 else { return }
        self.outer = outer
        self.inner = inner
        watcher.start(inner: inner)
        guard outer > 0, let port = NWEndpoint.Port(rawValue: UInt16(outer)) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return refused("no listener") }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { WebSocketLink(connection).start() }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.listening()
                case .failed(let error): self?.refused("\(error)")
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Why tools can't reach Search on its port, when they can't: another
    /// app has it, and tools reach that app instead (Settings › Engine).
    private(set) var trouble: String?

    private func listening() {
        // Started by Playwright on a port (Launch.swift): Chromium's line, on
        // stderr, which is where it reads the address back.
        guard Launch.active else { return }
        let outer = self.outer
        watcher.whenBrowserPath { path in
            FileHandle.standardError.write(Data("DevTools listening on ws://127.0.0.1:\(outer)\(path)\n".utf8))
        }
    }

    private func refused(_ error: String) {
        listener?.cancel()
        listener = nil
        trouble = "Another app has 127.0.0.1:\(outer), so tools reach it instead of Search. Quit it, then relaunch Search"
        guard Launch.active else { return }
        // Playwright shows what a browser said when it gave up starting.
        FileHandle.standardError.write(Data("Search can't listen on 127.0.0.1:\(outer): \(error)\n".utf8))
        NSApp.terminate(nil)
    }

    /// Playwright's pipe, file descriptors 3 and 4, when it started Search.
    func startPipe() {
        guard pipe == nil else { return }
        let made = PipeLink()
        pipe = made
        made.start()
    }

    var innerBase: String { "127.0.0.1:\(inner)" }

    /// Chromium's addresses, as tools should see them: on this port.
    func outward(_ text: String) -> String {
        guard outer > 0 else { return text }
        return text.replacingOccurrences(of: "127.0.0.1:\(inner)", with: "127.0.0.1:\(outer)")
            .replacingOccurrences(of: "localhost:\(inner)", with: "localhost:\(outer)")
    }

    func came(_ session: ToolSession) { sessions[ObjectIdentifier(session)] = session }

    func left(_ session: ToolSession) { sessions[ObjectIdentifier(session)] = nil }

    /// The pill's Disconnect: every tool's connection closed. One that
    /// started Search (the pipe) is told by Search quitting instead.
    func disconnectAll() {
        if pipe != nil { return NSApp.terminate(nil) }
        for session in Array(sessions.values) { session.close() }
    }

    /// An event for the tools driving one of Search's contexts, as
    /// Chromium would send it for one of its own.
    func event(_ method: String, _ params: [String: Any], context: String) {
        for session in sessions.values where session.owns(context) { session.emit(method, params) }
    }

    /// Chromium's list of targets (/json/list), without the ones tools don't
    /// see (see Automation.hides).
    func visible(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return body }
        let kept = entries.filter { entry in
            guard let id = entry["id"] as? String else { return true }
            return !Automation.shared.hides(target: id, context: watcher.context(of: id))
        }
        guard let out = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted]) else { return body }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - What Chromium has

/// A connection of Search's own to Chromium's browser target: the address
/// of its browser endpoint, the default context's id, and the context of
/// every target, for lists a tool asks for over HTTP.
@MainActor
final class TargetWatcher {
    private var socket: DevToolsSocket?
    private var inner = 0
    private(set) var browserPath: String?
    private var pathWaiters: [(String) -> Void] = []
    private var contexts: [String: String] = [:]

    func start(inner: Int) {
        self.inner = inner
        connect(attempt: 0)
    }

    func context(of target: String) -> String? { contexts[target] }

    /// `then` gets "/devtools/browser/<id>" once Chromium's server is up.
    func whenBrowserPath(_ then: @escaping (String) -> Void) {
        if let browserPath { return then(browserPath) }
        pathWaiters.append(then)
    }

    /// Chromium's server comes up a moment after Chromium does.
    private func connect(attempt: Int) {
        guard attempt < 120, let url = URL(string: "http://127.0.0.1:\(inner)/json/version") else { return }
        DevToolsNet.fetch(URLRequest(url: url)) { _, data in
            let found = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["webSocketDebuggerUrl"] as? String }
                .flatMap(URL.init(string:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let found else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.connect(attempt: attempt + 1) }
                        return
                    }
                    self.open(found)
                }
            }
        }
    }

    private func open(_ url: URL) {
        browserPath = url.path
        for waiter in pathWaiters { waiter(url.path) }
        pathWaiters.removeAll()
        socket = DevToolsNet.socket(url)
        send(["id": 1, "method": "Target.setDiscoverTargets", "params": ["discover": true]])
        send(["id": 2, "method": "Target.getBrowserContexts"])
        receive()
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket?.send(String(decoding: data, as: UTF8.self))
    }

    private func receive() {
        socket?.receive { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .success(let text) = result else { return }
                    self.heard(text)
                    self.receive()
                }
            }
        }
    }

    private func heard(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["id"] as? Int == 2, let result = message["result"] as? [String: Any],
           let id = result["defaultBrowserContextId"] as? String {
            Automation.shared.learnDefaultContext(id)
            return
        }
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            if let info = params["targetInfo"] as? [String: Any], let id = info["targetId"] as? String {
                contexts[id] = info["browserContextId"] as? String
            }
        case "Target.targetDestroyed":
            if let id = params["targetId"] as? String { contexts[id] = nil }
        default:
            break
        }
    }
}

// MARK: - One tool

/// One tool's connection, whatever carries it (a WebSocket, or the pipe):
/// its own connection to Chromium, and everything the bridge does to what
/// passes between them.
@MainActor
final class ToolSession {
    private let deliver: (String) -> Void
    private let hangUp: () -> Void
    private var upstream: DevToolsSocket?
    private var closed = false
    /// For a page's own endpoint (/devtools/page/<id>): the target every
    /// message without a session is for.
    private let pageTarget: String?

    /// Sessions attached on this connection, and the page each drives.
    private var sessions: [String: String] = [:]
    /// Pages attached at the top, which the tool has been told of.
    private var attached: Set<String> = []
    private var autoAttach = false
    private var attachWaiters: [String: [() -> Void]] = [:]
    /// What this tool must not see, and the sessions Search made for them.
    private var hidden: Set<String> = []
    private var hiddenSessions: Set<String> = []
    /// Sessions of Search's own on this connection, to ask a context's
    /// keeper things (cookies), by target.
    private var ownSessions: [String: String] = [:]
    private var ownAttaching: Set<String> = []
    private var ownWaiters: [String: [(String?) -> Void]] = [:]
    /// Requests of Search's own on this connection, by id: counting down
    /// from far above any a tool uses.
    private var nextOwn = 2_000_000_000
    private var own: [Int: ([String: Any]) -> Void] = [:]
    /// The tool's requests whose replies Search changes, by id.
    private var filtering: [Int: String] = [:]
    /// Search's contexts this tool made.
    private var contexts: Set<String> = []
    /// Frames below the top of a page, and the page: where a download
    /// started (Browser.downloadWillBegin names the frame).
    private var frames: [String: String] = [:]
    /// Chromium's word of downloads Search tells the tool of itself.
    private var echoes: Set<String> = []
    /// The context of each page attached at the top (not its workers,
    /// which needn't go first).
    private var pageContexts: [String: String] = [:]
    /// Target.disposeBrowserContext for one of Search's contexts, answered
    /// once the tool has heard each of its pages go, as Chromium answers it.
    private var disposals: [UUID: (context: String, then: () -> Void)] = [:]

    init(path: String, agent: String?, deliver: @escaping (String) -> Void, hangUp: @escaping () -> Void) {
        self.deliver = deliver
        self.hangUp = hangUp
        let page = "/devtools/page/"
        pageTarget = path.hasPrefix(page) ? String(path.dropFirst(page.count)) : nil
        DevToolsBridge.shared.came(self)
        Automation.shared.came(self, agent: agent)
        connect(path)
    }

    func owns(_ context: String) -> Bool { contexts.contains(context) }

    func close() {
        guard !closed else { return }
        closed = true
        upstream?.cancel()
        hangUp()
        Automation.shared.left(self)
        DevToolsBridge.shared.left(self)
    }

    // MARK: Chromium

    private func connect(_ path: String) {
        guard let url = URL(string: "ws://\(DevToolsBridge.shared.innerBase)\(path)") else { return close() }
        upstream = DevToolsNet.socket(url)
        receive()
    }

    private func receive() {
        upstream?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case .success(let text):
                        self.fromChromium(text)
                    case .failure:
                        return self.close()
                    }
                    self.receive()
                }
            }
        }
    }

    private func upstreamSend(_ text: String) {
        upstream?.send(text)
    }

    /// A request of Search's own, on this connection; the reply comes to
    /// `done` and never to the tool.
    private func request(_ method: String, _ params: [String: Any] = [:], session: String? = nil,
                         _ done: (([String: Any]) -> Void)? = nil) {
        let id = nextOwn
        nextOwn -= 1
        own[id] = done ?? { _ in }
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        upstreamSend(String(decoding: data, as: UTF8.self))
    }

    // MARK: To the tool

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        deliver(String(decoding: data, as: UTF8.self))
    }

    private func reply(_ id: Any?, _ session: String?, result: [String: Any] = [:]) {
        guard let id else { return }
        var message: [String: Any] = ["id": id, "result": result]
        if let session { message["sessionId"] = session }
        send(message)
    }

    private func reply(_ id: Any?, _ session: String?, error: String) {
        guard let id else { return }
        var message: [String: Any] = ["id": id, "error": ["code": -32000, "message": error]]
        if let session { message["sessionId"] = session }
        send(message)
    }

    /// An event at the browser's level, as Chromium sends its own.
    func emit(_ method: String, _ params: [String: Any]) {
        send(["method": method, "params": params])
    }

    // MARK: From the tool

    func fromTool(_ text: String) {
        guard !closed else { return }
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String
        else { return upstreamSend(text) }
        let id = message["id"]
        let session = message["sessionId"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        let target = session.flatMap { sessions[$0] } ?? (session == nil ? pageTarget : nil)
        if let target, ToolSession.drives(method) {
            Automation.shared.driving(target, input: method.hasPrefix("Input."))
        }
        if handled(method, id: id, session: session, target: target, params: params) { return }
        upstreamSend(text)
    }

    /// Search's part in a command: true when it answered it itself.
    private func handled(_ method: String, id: Any?, session: String?, target: String?, params: [String: Any]) -> Bool {
        let automation = Automation.shared
        let context = params["browserContextId"] as? String
        let named = params["targetId"] as? String
        // What the tool can't see, it can't reach either.
        if let named, hidden.contains(named) || automation.hides(target: named, context: nil),
           method.hasPrefix("Target.") || method == "Browser.getWindowForTarget" {
            reply(id, session, error: "No target with given id found")
            return true
        }
        switch method {
        case "Target.setAutoAttach":
            if session == nil { autoAttach = params["autoAttach"] as? Bool ?? false }
            return false

        case "Target.createTarget":
            let address = (params["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let url = address ?? URL(string: "about:blank")!
            let background = params["background"] as? Bool ?? false
            let tab: Tab
            if let context, automation.isSearchContext(context) {
                guard let made = automation.openPage(url, inContext: context, background: background) else {
                    reply(id, session, error: "That context has gone")
                    return true
                }
                tab = made
            } else if context == nil || context == automation.defaultContext {
                tab = automation.openPage(url, for: self, newWindow: params["newWindow"] as? Bool ?? false,
                                          background: background)
            } else {
                // A context of Chromium's own (see createBrowserContext).
                return false
            }
            automation.whenTarget(of: tab) { [weak self] made in
                guard let self else { return }
                guard let made else { return self.reply(id, session, error: "Search opened a tab, but its page never came up") }
                self.afterAttach(made) { self.reply(id, session, result: ["targetId": made]) }
            }
            return true

        case "Target.closeTarget":
            guard let named, let tab = automation.tab(for: named) else { return false }
            automation.close(tab)
            reply(id, session, result: ["success": true])
            return true

        case "Target.activateTarget":
            if let named, let tab = automation.tab(for: named) { automation.bringToFront(tab) }
            return false

        case "Target.getTargets":
            if let number = id as? Int { filtering[number] = method }
            return false

        case "Target.getBrowserContexts":
            if let number = id as? Int { filtering[number] = method }
            return false

        case "Target.createBrowserContext":
            automation.makeContext(for: self, disposeOnDetach: params["disposeOnDetach"] as? Bool ?? false,
                                   proxy: params["proxyServer"] as? String,
                                   bypass: params["proxyBypassList"] as? String) { [weak self] made in
                guard let self else { return }
                guard let made else {
                    // Search couldn't make one: Chromium's own, in its windows.
                    return self.request(method, params) { [weak self] answer in
                        guard let self else { return }
                        if let made = (answer["result"] as? [String: Any])?["browserContextId"] as? String {
                            automation.chromiumMadeContext(made)
                            self.reply(id, session, result: ["browserContextId": made])
                        } else {
                            self.reply(id, session, error: ((answer["error"] as? [String: Any])?["message"] as? String) ?? "No context")
                        }
                    }
                }
                self.contexts.insert(made)
                self.reply(id, session, result: ["browserContextId": made])
            }
            return true

        case "Target.disposeBrowserContext":
            guard let context, automation.isSearchContext(context) else { return false }
            contexts.remove(context)
            automation.dispose(context)
            whenGone(context) { [weak self] in self?.reply(id, session) }
            return true

        case "Browser.setDownloadBehavior":
            let behavior = params["behavior"] as? String ?? "default"
            let path = params["downloadPath"] as? String
            if let context, automation.isSearchContext(context) {
                automation.downloadBehavior(behavior, path: path, context: context)
                reply(id, session)
                return true
            }
            if context == nil || context == automation.defaultContext {
                automation.downloadBehavior(behavior, path: path, context: nil)
            }
            return false

        case "Browser.cancelDownload":
            guard let context, automation.isSearchContext(context) else { return false }
            automation.cancelDownload(params["guid"] as? String ?? "", context: context)
            reply(id, session)
            return true

        case "Browser.grantPermissions":
            let permissions = params["permissions"] as? [String] ?? []
            let origin = params["origin"] as? String
            if let context, automation.isSearchContext(context) {
                automation.grant(permissions, origin: origin, context: context)
                reply(id, session)
                return true
            }
            if context == nil || context == automation.defaultContext {
                automation.grant(permissions, origin: origin, context: nil)
            }
            return false

        case "Browser.resetPermissions":
            if let context, automation.isSearchContext(context) {
                automation.resetGrants(context: context)
                reply(id, session)
                return true
            }
            if context == nil || context == automation.defaultContext { automation.resetGrants(context: nil) }
            return false

        case "Storage.getCookies", "Storage.setCookies", "Storage.clearCookies":
            guard let context, automation.isSearchContext(context) else { return false }
            cookies(method, params: params, context: context) { [weak self] answer, error in
                guard let self else { return }
                if let error { return self.reply(id, session, error: error) }
                self.reply(id, session, result: answer)
            }
            return true

        case "Browser.getWindowForTarget":
            // A Search tab is in a window of Search's, which Chrome's frame
            // sizes don't fit: Playwright, told so, leaves it alone.
            let page = named ?? target
            guard let page, automation.tab(for: page) != nil else { return false }
            reply(id, session, error: "Browser window not found")
            return true

        case "Page.bringToFront":
            if let target, let tab = automation.tab(for: target) { automation.bringToFront(tab) }
            return false

        case "Emulation.setDeviceMetricsOverride":
            if let target {
                let width = (params["width"] as? NSNumber)?.intValue ?? 0
                let height = (params["height"] as? NSNumber)?.intValue ?? 0
                automation.viewport(target, width: width, height: height)
            }
            return false

        case "Emulation.clearDeviceMetricsOverride":
            if let target { automation.viewport(target, width: 0, height: 0) }
            return false

        case "Input.dispatchMouseEvent":
            if let target {
                let x = (params["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (params["y"] as? NSNumber)?.doubleValue ?? 0
                automation.pointer(target, type: params["type"] as? String ?? "", x: x, y: y)
            }
            return false

        case "Browser.close":
            reply(id, session)
            if Launch.active {
                // Playwright's browser.close(): the run is over.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } else {
                // Your Search stays: only what this tool opened goes.
                automation.closeWindows(of: self)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close() }
            }
            return true

        case "Browser.crash", "Browser.crashGpuProcess":
            guard !Launch.active else { return false }
            reply(id, session, error: "Search doesn't let a tool it didn't start crash it")
            return true

        default:
            return false
        }
    }

    /// A tool doing something to a page — not what it sends every page it
    /// attaches to, which on connecting is every tab of yours.
    private static func drives(_ method: String) -> Bool {
        if method.hasPrefix("Input.") || method.hasPrefix("DOM.") || method.hasPrefix("Accessibility.") {
            return !method.hasSuffix(".enable") && !method.hasSuffix(".disable")
        }
        return actions.contains(method)
    }

    private static let actions: Set<String> = [
        "Page.navigate", "Page.reload", "Page.navigateToHistoryEntry", "Page.captureScreenshot", "Page.startScreencast",
        "Page.printToPDF", "Page.bringToFront", "Page.close", "Page.setDocumentContent", "Page.handleJavaScriptDialog",
        "Runtime.evaluate", "Runtime.callFunctionOn", "Emulation.setDeviceMetricsOverride",
    ]

    /// Answers once the tool has been told of the page — Chrome answers
    /// Target.createTarget after the page is attached, and Playwright
    /// counts on it.
    private func afterAttach(_ target: String, _ then: @escaping () -> Void) {
        guard autoAttach, !attached.contains(target) else { return then() }
        attachWaiters[target, default: []].append(then)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let waiters = self.attachWaiters.removeValue(forKey: target) else { return }
            for waiter in waiters { waiter() }
        }
    }

    private func whenGone(_ context: String, _ then: @escaping () -> Void) {
        guard pageContexts.values.contains(context) else { return then() }
        let key = UUID()
        disposals[key] = (context, then)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.disposals.removeValue(forKey: key)?.then()
        }
    }

    /// A context's cookies, through a page in it (its keeper): what
    /// Storage.* would do for one of Chromium's own.
    private func cookies(_ method: String, params: [String: Any], context: String,
                         _ done: @escaping ([String: Any], String?) -> Void) {
        guard let keeper = Automation.shared.keeperTarget(of: context) else { return done([:], "That context has gone") }
        ownSession(for: keeper) { [weak self] session in
            guard let self else { return }
            guard let session else { return done([:], "That context has no page to ask") }
            switch method {
            case "Storage.getCookies":
                self.request("Network.getAllCookies", session: session) { answer in
                    let cookies = (answer["result"] as? [String: Any])?["cookies"] ?? []
                    done(["cookies": cookies], nil)
                }
            case "Storage.setCookies":
                self.request("Network.setCookies", ["cookies": params["cookies"] ?? []], session: session) { answer in
                    done([:], (answer["error"] as? [String: Any])?["message"] as? String)
                }
            default:
                self.request("Network.clearBrowserCookies", session: session) { answer in
                    done([:], (answer["error"] as? [String: Any])?["message"] as? String)
                }
            }
        }
    }

    /// A session of Search's own on this connection, to a page the tool
    /// doesn't see.
    private func ownSession(for target: String, _ then: @escaping (String?) -> Void) {
        if let session = ownSessions[target] { return then(session) }
        ownWaiters[target, default: []].append(then)
        guard !ownAttaching.contains(target) else { return }
        ownAttaching.insert(target)
        request("Target.attachToTarget", ["targetId": target, "flatten": true]) { [weak self] answer in
            guard let self else { return }
            self.ownAttaching.remove(target)
            let session = (answer["result"] as? [String: Any])?["sessionId"] as? String
            if let session { self.ownSessions[target] = session }
            for waiter in self.ownWaiters.removeValue(forKey: target) ?? [] { waiter(session) }
        }
    }

    // MARK: From Chromium

    /// The events Search acts on, or keeps from the tool.
    private static let watched: Set<String> = [
        "Target.attachedToTarget", "Target.detachedFromTarget", "Target.targetCreated", "Target.targetInfoChanged",
        "Target.targetDestroyed", "Target.targetCrashed", "Page.javascriptDialogClosed", "Browser.downloadWillBegin",
        "Browser.downloadProgress", "Page.frameAttached", "Page.frameDetached",
    ]

    private func fromChromium(_ text: String) {
        // Most go straight through, unread: a screenshot is megabytes.
        if let method = ToolSession.method(of: text) {
            if ToolSession.watched.contains(method) {
                guard let message = ToolSession.parse(text) else { return deliver(text) }
                if let session = message["sessionId"] as? String, isOwnOrHidden(session) { return }
                guard event(method, message) else { return }
            } else if quietSession(of: text) {
                return
            }
        } else if let number = ToolSession.id(of: text), own[number] != nil || filtering[number] != nil {
            guard let message = ToolSession.parse(text) else { return deliver(text) }
            if let done = own.removeValue(forKey: number) { return done(message) }
            if let method = filtering.removeValue(forKey: number) { return send(filtered(method, message)) }
        } else if quietSession(of: text) {
            return
        }
        deliver(text)
    }

    private func isOwnOrHidden(_ session: String) -> Bool {
        hiddenSessions.contains(session) || ownSessions.values.contains(session)
    }

    /// A message of a session the tool doesn't know: one of Search's own,
    /// or a hidden page's. Chromium puts the session last.
    private func quietSession(of text: String) -> Bool {
        guard !hiddenSessions.isEmpty || !ownSessions.isEmpty else { return false }
        for session in hiddenSessions.union(ownSessions.values) where text.hasSuffix("\"sessionId\":\"\(session)\"}") {
            return true
        }
        return false
    }

    /// Search's part in an event: false to keep it from the tool.
    private func event(_ method: String, _ message: [String: Any]) -> Bool {
        let automation = Automation.shared
        let params = message["params"] as? [String: Any] ?? [:]
        let outer = message["sessionId"] as? String
        let info = params["targetInfo"] as? [String: Any]
        let targetID = (info?["targetId"] as? String) ?? (params["targetId"] as? String)
        switch method {
        case "Target.attachedToTarget":
            guard let session = params["sessionId"] as? String, let targetID else { return true }
            if ownAttaching.contains(targetID) {
                ownSessions[targetID] = session
                return false
            }
            if outer == nil, automation.hides(target: targetID, context: info?["browserContextId"] as? String) {
                // Let go of at once: resumed, so it isn't left waiting for a
                // debugger it will never see, and detached.
                hidden.insert(targetID)
                hiddenSessions.insert(session)
                if params["waitingForDebugger"] as? Bool == true {
                    request("Runtime.runIfWaitingForDebugger", session: session)
                }
                request("Target.detachFromTarget", ["sessionId": session])
                return false
            }
            // A frame's or a worker's session drives the page it belongs to.
            sessions[session] = outer.flatMap { sessions[$0] } ?? targetID
            if outer == nil {
                attached.insert(targetID)
                if info?["type"] as? String == "page" { pageContexts[targetID] = info?["browserContextId"] as? String }
                if let waiters = attachWaiters.removeValue(forKey: targetID) {
                    // After this event has reached the tool.
                    DispatchQueue.main.async { for waiter in waiters { waiter() } }
                }
            }
            return true

        case "Target.detachedFromTarget":
            guard let session = params["sessionId"] as? String else { return true }
            if hiddenSessions.remove(session) != nil { return false }
            if let owned = ownSessions.first(where: { $0.value == session }) {
                ownSessions[owned.key] = nil
                return false
            }
            if outer == nil, let page = sessions[session] {
                attached.remove(page)
                frames = frames.filter { $0.value != page }
                pageContexts[page] = nil
                for (key, disposal) in disposals where !pageContexts.values.contains(disposal.context) {
                    disposals[key] = nil
                    // After this event has reached the tool.
                    DispatchQueue.main.async { disposal.then() }
                }
            }
            sessions[session] = nil
            return true

        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let targetID else { return true }
            if hidden.contains(targetID) || automation.hides(target: targetID, context: info?["browserContextId"] as? String) {
                hidden.insert(targetID)
                return false
            }
            return true

        case "Target.targetDestroyed", "Target.targetCrashed":
            guard let targetID, hidden.contains(targetID) else { return true }
            if method == "Target.targetDestroyed" { hidden.remove(targetID) }
            return false

        case "Page.javascriptDialogClosed":
            // Answered — by this tool or another way: Search's sheet for it goes.
            if let outer, let page = sessions[outer], let tab = automation.tab(for: page) {
                Automation.browser(of: tab)?.chromiumQuestionGone(tab)
            }
            return true

        case "Page.frameAttached":
            if let outer, let page = sessions[outer], let frame = params["frameId"] as? String { frames[frame] = page }
            return true

        case "Page.frameDetached":
            if params["reason"] as? String != "swap", let frame = params["frameId"] as? String { frames[frame] = nil }
            return true

        case "Browser.downloadWillBegin":
            guard let guid = params["guid"] as? String else { return true }
            // Chromium tells every tool that asked for download events of
            // every download, whatever its context: those in Search's are
            // told by Search, saved where the tool asked.
            if let frame = params["frameId"] as? String, automation.inSearchContext(target: frames[frame] ?? frame) {
                echoes.insert(guid)
                return false
            }
            automation.downloadBegan(guid: guid, url: params["url"] as? String ?? "",
                                     name: params["suggestedFilename"] as? String ?? "")
            return true

        case "Browser.downloadProgress":
            guard let guid = params["guid"] as? String else { return true }
            let state = params["state"] as? String ?? ""
            if echoes.contains(guid) {
                if state != "inProgress" { echoes.remove(guid) }
                return false
            }
            automation.downloadProgressed(guid: guid, state: state)
            return true

        default:
            return true
        }
    }

    /// A reply Search changes before the tool sees it.
    private func filtered(_ method: String, _ message: [String: Any]) -> [String: Any] {
        guard var result = message["result"] as? [String: Any] else { return message }
        var out = message
        switch method {
        case "Target.getTargets":
            let infos = result["targetInfos"] as? [[String: Any]] ?? []
            result["targetInfos"] = infos.filter { info in
                guard let id = info["targetId"] as? String else { return true }
                return !hidden.contains(id) && !Automation.shared.hides(target: id, context: info["browserContextId"] as? String)
            }
        case "Target.getBrowserContexts":
            let ids = result["browserContextIds"] as? [String] ?? []
            result["browserContextIds"] = ids + contexts.sorted().filter { !ids.contains($0) }
        default:
            break
        }
        out["result"] = result
        return out
    }

    // MARK: Reading a message without reading all of it

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// An event's method: Chromium writes it first.
    private static func method(of text: String) -> String? {
        let start = "{\"method\":\""
        guard text.hasPrefix(start) else { return nil }
        let rest = text.dropFirst(start.count)
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// A reply's id: Chromium writes it first.
    private static func id(of text: String) -> Int? {
        let start = "{\"id\":"
        guard text.hasPrefix(start) else { return nil }
        let digits = text.dropFirst(start.count).prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }
}

// MARK: - A tool on the pipe

/// Playwright's pipe, when it started Search: what it writes on file
/// descriptor 3, and what it reads on 4, each message ended by a zero byte.
/// It closing is Playwright gone, and the run with it.
@MainActor
private final class PipeLink {
    private let input = FileHandle(fileDescriptor: 3, closeOnDealloc: false)
    private let output = FileHandle(fileDescriptor: 4, closeOnDealloc: false)
    private var buffer = Data()
    private var session: ToolSession?
    /// What came before Chromium's server was up.
    private var early: [String] = []

    func start() {
        // A write after Playwright has gone mustn't take Search down with a
        // signal: it quits on its own (see received).
        signal(SIGPIPE, SIG_IGN)
        input.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.received(data) }
            }
        }
        DevToolsBridge.shared.watcher.whenBrowserPath { [weak self] path in
            guard let self else { return }
            let made = ToolSession(path: path, agent: "Playwright", deliver: { [weak self] text in
                self?.write(text)
            }, hangUp: { [weak self] in
                self?.input.readabilityHandler = nil
            })
            self.session = made
            for message in self.early { made.fromTool(message) }
            self.early.removeAll()
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else {
            input.readabilityHandler = nil
            NSApp.terminate(nil)
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0) {
            let message = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...end)
            if let session {
                session.fromTool(message)
            } else {
                early.append(message)
            }
        }
    }

    private func write(_ text: String) {
        var data = Data(text.utf8)
        data.append(0)
        try? output.write(contentsOf: data)
    }
}

// MARK: - A tool on the port

/// A client of the debugging port: plain HTTP for /json, passed through;
/// or a WebSocket, which becomes a ToolSession.
@MainActor
private final class WebSocketLink {
    private let connection: NWConnection
    private var buffer = Data()
    private var session: ToolSession?
    /// Fragments of a message still arriving.
    private var partial = Data()
    private var closed = false
    /// Kept alive while the connection is.
    private static var all: [ObjectIdentifier: WebSocketLink] = [:]

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        WebSocketLink.all[ObjectIdentifier(self)] = self
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        readHead()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        session?.close()
        connection.cancel()
        WebSocketLink.all.removeValue(forKey: ObjectIdentifier(self))
    }

    // MARK: The request

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                    self.buffer.removeSubrange(..<end.upperBound)
                    self.handle(head)
                } else if done || error != nil || self.buffer.count > 65536 {
                    self.finish()
                } else {
                    self.readHead()
                }
            }
        }
    }

    private func handle(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return finish() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let host = (headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host.lowercased()) else {
            return respond(403, "Host must be 127.0.0.1 or localhost.")
        }
        let method = String(request[0]), path = String(request[1])
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            // A web page's WebSocket says where it comes from; a tool's doesn't.
            if let origin = headers["origin"], !origin.hasPrefix("devtools://") {
                return respond(403, "Rejected: a page at \(origin) can't drive Search.")
            }
            join(path: path, key: key, agent: headers["user-agent"])
        } else {
            pass(method: method, path: path)
        }
    }

    private func respond(_ status: Int, _ body: String, type: String = "text/plain") {
        let data = Data(body.utf8)
        let reason = status == 200 ? "OK" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type); charset=UTF-8\r\n"
            + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    /// /json, /json/version, /json/list and the rest: Chromium's answer,
    /// with its port turned into this one and what tools don't see taken
    /// out. /json/new opens a Search tab; /json/close and /json/activate
    /// act on one.
    private func pass(method: String, path: String) {
        let bridge = DevToolsBridge.shared
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if route.hasPrefix("/json/close/") || route.hasPrefix("/json/activate/") {
            let id = String(route.split(separator: "/").last ?? "")
            if let tab = Automation.shared.tab(for: id) {
                if route.hasPrefix("/json/close/") {
                    Automation.shared.close(tab)
                    return respond(200, "Target is closing")
                }
                Automation.shared.bringToFront(tab)
                return respond(200, "Target activated")
            }
            if Automation.shared.hides(target: id, context: bridge.watcher.context(of: id)) {
                return respond(404, "No such target id: \(id)")
            }
        }
        if route == "/json/new" {
            let given = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
            let url = given.flatMap { URL(string: $0.removingPercentEncoding ?? $0) } ?? URL(string: "about:blank")!
            let tab = Automation.shared.openPage(url, for: self, newWindow: false, background: false)
            Automation.shared.whenTarget(of: tab) { [weak self] target in
                guard let self else { return }
                guard let target else { return self.respond(500, "Search opened a tab, but its page never came up") }
                self.fetch("GET", "/json/list") { status, body in
                    let entries = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]) ?? []
                    guard let entry = entries.first(where: { $0["id"] as? String == target }),
                          let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted]) else {
                        return self.respond(status == 200 ? 500 : status, "No entry for the new tab")
                    }
                    self.respond(200, bridge.outward(String(decoding: data, as: UTF8.self)), type: "application/json")
                }
            }
            return
        }
        fetch(method, path) { [weak self] status, body in
            guard let self else { return }
            let listed = route == "/json" || route == "/json/list" ? bridge.visible(body) : body
            self.respond(status, bridge.outward(listed), type: "application/json")
        }
    }

    private func fetch(_ method: String, _ path: String, _ done: @escaping (Int, String) -> Void) {
        guard let url = URL(string: "http://\(DevToolsBridge.shared.innerBase)\(path)") else { return done(400, "Bad path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        DevToolsNet.fetch(request) { status, data in
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(status, body) }
            }
        }
    }

    // MARK: The WebSocket

    private func join(path: String, key: String, agent: String?) {
        let page = "/devtools/page/"
        if path.hasPrefix(page) {
            let id = String(path.dropFirst(page.count))
            if Automation.shared.hides(target: id, context: DevToolsBridge.shared.watcher.context(of: id)) {
                return respond(404, "No such target id: \(id)")
            }
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        session = ToolSession(path: path, agent: agent, deliver: { [weak self] text in
            self?.write(Data(text.utf8), opcode: 0x1)
        }, hangUp: { [weak self] in
            guard let self, !self.closed else { return }
            self.write(Data([0x03, 0xE8]), opcode: 0x8)
            self.finish()
        })
        frames()
    }

    /// One frame to the tool: never masked, never fragmented.
    private func write(_ payload: Data, opcode: UInt8) {
        guard !closed else { return }
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:
            frame.append(UInt8(payload.count))
        case ..<65536:
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Frames from the tool, which RFC 6455 has masked.
    private func frames() {
        while let (fin, opcode, payload, used) = WebSocketLink.frame(in: buffer) {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + used)
            switch opcode {
            case 0x0, 0x1, 0x2:
                partial.append(payload)
                if fin {
                    let message = partial
                    partial = Data()
                    session?.fromTool(String(decoding: message, as: UTF8.self))
                }
            case 0x8:
                write(Data(), opcode: 0x8)
                return finish()
            case 0x9:
                write(payload, opcode: 0xA)
            default:
                break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                if done || error != nil { return self.finish() }
                self.frames()
            }
        }
    }

    private static func frame(in data: Data) -> (Bool, UInt8, Data, Int)? {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0F, masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F), at = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            at = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            at = 10
        }
        let mask = masked ? 4 : 0
        guard data.count >= at + mask + length else { return nil }
        let start = data.startIndex + at
        var payload = Data(data[start + mask..<start + mask + length])
        if masked {
            let key = [UInt8](data[start..<start + 4])
            payload.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] ^= key[i & 3] }
            }
        }
        return (fin, opcode, payload, at + mask + length)
    }
}
