import Foundation
import FoundationNetworking
#if canImport(Glibc)
import Glibc
#endif

// A WebSocket client and an HTTP GET on plain sockets, for the bridge to
// reach Chromium on Linux, where Foundation's can't.

private func connectTo(port: Int) -> Int32 {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if ok != 0 { close(fd); return -1 }
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    while sent < data.count {
        let n = data.withUnsafeBytes { raw in Glibc.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, Int32(MSG_NOSIGNAL)) }
        if n <= 0 { return false }
        sent += n
    }
    return true
}

private func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var out = Data(count: count)
    var got = 0
    while got < count {
        let n = out.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress!.advanced(by: got), count - got) }
        if n <= 0 { return nil }
        got += n
    }
    return out
}

final class PosixSocket: DevToolsSocket, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let writing = NSLock()
    private var messages: [Result<String, Error>] = []
    private var waiting: ((Result<String, Error>) -> Void)?
    private var ended = false

    struct Ended: Error {}

    init(url: URL) {
        fd = connectTo(port: url.port ?? 80)
        guard fd >= 0 else { ended = true; messages.append(.failure(Ended())); return }
        let hello = "GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(url.port ?? 80)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        _ = writeAll(fd, Data(hello.utf8))
        var head = Data()
        while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard let byte = readExactly(fd, 1) else { break }
            head.append(byte)
        }
        let thread = Thread { [self] in readLoop() }
        thread.start()
    }

    private func readLoop() {
        var partial = Data()
        while true {
            guard let head = readExactly(fd, 2) else { return deliver(.failure(Ended())) }
            let fin = head[0] & 0x80 != 0, opcode = head[0] & 0x0F
            var length = Int(head[1] & 0x7F)
            if length == 126 {
                guard let more = readExactly(fd, 2) else { return deliver(.failure(Ended())) }
                length = Int(more[0]) << 8 | Int(more[1])
            } else if length == 127 {
                guard let more = readExactly(fd, 8) else { return deliver(.failure(Ended())) }
                length = more.reduce(0) { $0 << 8 | Int($1) }
            }
            guard let payload = length > 0 ? readExactly(fd, length) : Data() else { return deliver(.failure(Ended())) }
            switch opcode {
            case 0, 1, 2:
                partial.append(payload)
                if fin {
                    deliver(.success(String(decoding: partial, as: UTF8.self)))
                    partial = Data()
                }
            case 8:
                return deliver(.failure(Ended()))
            default:
                continue
            }
        }
    }

    private func deliver(_ result: Result<String, Error>) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting(result)
        } else {
            messages.append(result)
            lock.unlock()
        }
    }

    func receive(_ then: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        if !messages.isEmpty {
            let message = messages.removeFirst()
            lock.unlock()
            DispatchQueue.global().async { then(message) }
        } else {
            waiting = then
            lock.unlock()
        }
    }

    func send(_ text: String) {
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count < 65536 {
            frame += [UInt8(0x80 | 126), UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        frame += mask
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i & 3]) }
        writing.lock()
        _ = writeAll(fd, Data(frame))
        writing.unlock()
    }

    func cancel() {
        shutdown(fd, Int32(SHUT_RDWR))
    }
}

/// An HTTP request to Chromium's server: its status and body.
func posixFetch(_ request: URLRequest, _ done: @escaping (Int, Data?) -> Void) {
    DispatchQueue.global().async {
        guard let url = request.url else { return done(400, nil) }
        let fd = connectTo(port: url.port ?? 80)
        guard fd >= 0 else { return done(502, nil) }
        defer { close(fd) }
        var path = url.path
        if let query = url.query { path += "?" + query }
        let text = "\(request.httpMethod ?? "GET") \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(url.port ?? 80)\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd, Data(text.utf8))
        // Read to the end of the body: Chromium's server keeps the
        // connection open whatever the request says.
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var split: Range<Data.Index>?
        var length: Int?
        while true {
            if split == nil, let found = all.range(of: Data([13, 10, 13, 10])) {
                split = found
                let head = String(decoding: all[..<found.lowerBound], as: UTF8.self).lowercased()
                length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
            }
            if let split, let length, all.count - split.upperBound >= length { break }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            all.append(contentsOf: buffer[0..<n])
        }
        guard let split else { return done(502, nil) }
        let head = String(decoding: all[..<split.lowerBound], as: UTF8.self)
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 502
        done(status, Data(all[split.upperBound...]))
    }
}
