import AppKit
import CryptoKit
import Network

// What Playwright and other DevTools clients reach on the debugging port.
// Chromium's own DevTools server listens one port up, and this passes
// everything through to it, with one difference: a target a tool asks for
// (Playwright's newPage) opens as a real Search tab, in the window in front,
// instead of a bare window of Chromium's that Search knows nothing of. Such
// a tab closes the way Search closes tabs when the tool closes it.
//
// Only 127.0.0.1, like Chromium's own server; requests whose Host isn't a
// loopback address are turned away, so a web page can't reach it through
// DNS rebinding.

@MainActor
final class DevToolsBridge {
    static let shared = DevToolsBridge()

    private var listener: NWListener?
    private var outer = 0
    private var inner = 0
    private let watcher = TargetWatcher()
    /// Tabs opened for a tool, by their DevTools target.
    private var opened: [String: (tab: Tab, browser: Browser)] = [:]

    /// Starts listening on `outer` for a Chromium whose own server is on
    /// `inner`. Once a run.
    func start(outer: Int, inner: Int) {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: UInt16(outer)) else { return }
        self.outer = outer
        self.inner = inner
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { Client(connection, bridge: DevToolsBridge.shared).start() }
        }
        listener.start(queue: .main)
        self.listener = listener
        watcher.start(inner: inner)
    }

    var innerBase: String { "127.0.0.1:\(inner)" }

    /// Chromium's addresses, as tools should see them: on this port.
    func outward(_ text: String) -> String {
        text.replacingOccurrences(of: "127.0.0.1:\(inner)", with: "127.0.0.1:\(outer)")
            .replacingOccurrences(of: "localhost:\(inner)", with: "localhost:\(outer)")
    }

    // MARK: - Commands Search answers itself

    /// The answer to `message` when Search handles it, through `reply`;
    /// false to pass it on to Chromium.
    func intercept(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) -> Bool {
        guard let id = message["id"], let method = message["method"] as? String else { return false }
        let params = message["params"] as? [String: Any] ?? [:]
        func answer(_ result: [String: Any]? = nil, error: String? = nil) {
            var out: [String: Any] = ["id": id]
            if let session = message["sessionId"] { out["sessionId"] = session }
            if let error { out["error"] = ["code": -32000, "message": error] } else { out["result"] = result ?? [:] }
            reply(out)
        }
        switch method {
        case "Target.createTarget":
            // A context of the tool's own (newContext) stays Chromium's:
            // Search has no window for it.
            guard params["browserContextId"] == nil, let browser = Browsers.front else { return false }
            let url = (params["url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "about:blank")!
            let background = params["background"] as? Bool ?? false
            var tab: Tab?
            watcher.expect { [weak self] target in
                guard let target else {
                    answer(error: "Search opened a tab, but Chromium never reported its page.")
                    return
                }
                if let tab { self?.opened[target] = (tab, browser) }
                answer(["targetId": target])
            }
            tab = browser.open(url, foreground: !background)
            return true
        case "Target.closeTarget":
            guard let target = params["targetId"] as? String, let made = opened.removeValue(forKey: target) else {
                return false
            }
            made.browser.close(made.tab)
            answer(["success": true])
            return true
        default:
            return false
        }
    }
}

// MARK: - Which target a new tab became

/// A connection of its own to Chromium's browser target that hears every
/// page come and go, so a tab Search opened for a tool can be named by the
/// target it became: the first page created after it was asked for.
@MainActor
private final class TargetWatcher {
    private var socket: URLSessionWebSocketTask?
    private var primed = false
    private var waiting: [(id: UUID, done: (String?) -> Void)] = []
    private var inner = 0

    func start(inner: Int) {
        self.inner = inner
        connect(attempt: 0)
    }

    /// `done` gets the next page's target, or nil after ten seconds.
    func expect(_ done: @escaping (String?) -> Void) {
        let id = UUID()
        waiting.append((id, done))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let at = self.waiting.firstIndex(where: { $0.id == id }) else { return }
            self.waiting.remove(at: at).done(nil)
        }
    }

    /// Chromium's server comes up a moment after Chromium does.
    private func connect(attempt: Int) {
        guard attempt < 60, let url = URL(string: "http://127.0.0.1:\(inner)/json/version") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let found = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["webSocketDebuggerUrl"] as? String }
                .flatMap(URL.init(string:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let found else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect(attempt: attempt + 1) }
                        return
                    }
                    self.open(found)
                }
            }
        }.resume()
    }

    private func open(_ url: URL) {
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 64 << 20
        self.socket = socket
        socket.resume()
        // The pages already open are reported first, before the answer to
        // this: none of them is anything asked for.
        send(["id": 1, "method": "Target.setDiscoverTargets", "params": ["discover": true]])
        receive()
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receive() {
        socket?.receive { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .success(let message) = result else { return }
                    if case .string(let text) = message { self.heard(text) }
                    self.receive()
                }
            }
        }
    }

    private func heard(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["id"] as? Int == 1 {
            primed = true
            return
        }
        guard primed, message["method"] as? String == "Target.targetCreated",
              let info = (message["params"] as? [String: Any])?["targetInfo"] as? [String: Any],
              info["type"] as? String == "page", let target = info["targetId"] as? String,
              !waiting.isEmpty else { return }
        waiting.removeFirst().done(target)
    }
}

// MARK: - One tool's connection

/// A client of the debugging port: plain HTTP for /json, passed through;
/// or a WebSocket, joined to one of Chromium's.
@MainActor
private final class Client {
    private let connection: NWConnection
    private unowned let bridge: DevToolsBridge
    private var buffer = Data()
    private var upstream: URLSessionWebSocketTask?
    /// Fragments of a message still arriving.
    private var partial = Data()
    private var closed = false
    /// Kept alive while the connection is.
    private static var all: [ObjectIdentifier: Client] = [:]

    init(_ connection: NWConnection, bridge: DevToolsBridge) {
        self.connection = connection
        self.bridge = bridge
    }

    func start() {
        Client.all[ObjectIdentifier(self)] = self
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
        upstream?.cancel(with: .goingAway, reason: nil)
        connection.cancel()
        Client.all.removeValue(forKey: ObjectIdentifier(self))
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
            join(path: path, key: key)
        } else {
            pass(method: method, path: path)
        }
    }

    private func respond(_ status: Int, _ body: String, type: String = "text/plain") {
        let data = Data(body.utf8)
        let reason = status == 200 ? "OK" : status == 403 ? "Forbidden" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type); charset=UTF-8\r\n"
            + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    /// /json, /json/version, /json/new and the rest: Chromium's answer,
    /// with its port turned into this one.
    private func pass(method: String, path: String) {
        guard let url = URL(string: "http://\(bridge.innerBase)\(path)") else { return respond(400, "Bad path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 502
                    let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.respond(status, self.bridge.outward(body), type: "application/json")
                }
            }
        }.resume()
    }

    // MARK: The WebSocket

    private func join(path: String, key: String) {
        guard let url = URL(string: "ws://\(bridge.innerBase)\(path)") else { return respond(400, "Bad path.") }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let upstream = URLSession.shared.webSocketTask(with: url)
        upstream.maximumMessageSize = 256 << 20
        self.upstream = upstream
        upstream.resume()
        fromChromium()
        frames()
    }

    private func fromChromium() {
        upstream?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case .success(.string(let text)):
                        self.write(Data(self.bridge.outward(text).utf8), opcode: 0x1)
                    case .success(.data(let data)):
                        self.write(data, opcode: 0x2)
                    case .failure:
                        self.write(Data([0x03, 0xE8]), opcode: 0x8)
                        return self.finish()
                    @unknown default:
                        break
                    }
                    self.fromChromium()
                }
            }
        }
    }

    /// One frame to the tool: never masked, never fragmented.
    private func write(_ payload: Data, opcode: UInt8) {
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
        while let (fin, opcode, payload, used) = Client.frame(in: buffer) {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + used)
            switch opcode {
            case 0x0, 0x1, 0x2:
                partial.append(payload)
                if fin {
                    let message = partial
                    partial = Data()
                    toChromium(message)
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

    private func toChromium(_ message: Data) {
        if let parsed = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
           bridge.intercept(parsed, reply: { [weak self] answer in
               guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return }
               self?.write(data, opcode: 0x1)
           }) {
            return
        }
        upstream?.send(.string(String(decoding: message, as: UTF8.self))) { _ in }
    }
}
