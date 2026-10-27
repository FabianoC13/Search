@_exported import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The part of Network.framework the bridge uses — a TCP listener on
// 127.0.0.1 and its connections — on POSIX sockets, for a harness on Linux.

public final class NWParameters {
    public static var tcp: NWParameters { NWParameters() }
    public var requiredLocalEndpoint: NWEndpoint?
    public var allowLocalEndpointReuse = false
}

public enum NWEndpoint {
    case hostPort(host: Host, port: Port)
    public struct Host: ExpressibleByStringLiteral { public init(stringLiteral: String) {} }
    public struct Port { public let rawValue: UInt16; public init?(rawValue: UInt16) { self.rawValue = rawValue } }
}

public enum NWError: Error { case posix(Int32) }

public final class NWListener: @unchecked Sendable {
    public enum State { case setup, waiting(NWError), ready, failed(NWError), cancelled }

    private let fd: Int32
    private let bound: Int32
    public var newConnectionHandler: ((NWConnection) -> Void)?
    public var stateUpdateHandler: ((State) -> Void)?

    public init(using parameters: NWParameters) throws {
        guard case .hostPort(_, let port)? = parameters.requiredLocalEndpoint else { throw NWError.posix(EINVAL) }
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.rawValue.bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let named = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        fd = descriptor
        // As Network.framework does: a port in use is said by the state, later.
        bound = named == 0 && listen(descriptor, 64) == 0 ? 0 : errno
    }

    public func start(queue: DispatchQueue) {
        guard bound == 0 else {
            let error = bound
            queue.async { self.stateUpdateHandler?(.failed(.posix(error))) }
            return
        }
        queue.async { self.stateUpdateHandler?(.ready) }
        Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                queue.async { self.newConnectionHandler?(NWConnection(fd: client)) }
            }
        }.start()
    }

    public func cancel() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }
}

public final class NWConnection: @unchecked Sendable {
    public enum State { case setup, ready, failed(NWError), cancelled }
    public enum SendCompletion { case contentProcessed((NWError?) -> Void) }

    private let fd: Int32
    private var queue = DispatchQueue.main
    private let reading = DispatchQueue(label: "read")
    private let writing = DispatchQueue(label: "write")
    private var cancelled = false
    public var stateUpdateHandler: ((State) -> Void)?

    init(fd: Int32) { self.fd = fd }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { self.stateUpdateHandler?(.ready) }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        shutdown(fd, Int32(SHUT_RDWR))
        writing.async { close(self.fd) }
        queue.async { self.stateUpdateHandler?(.cancelled) }
    }

    public func send(content: Data?, completion: SendCompletion) {
        let data = content ?? Data()
        writing.async {
            var sent = 0
            nonisolated(unsafe) var failed = false
            while sent < data.count {
                let n = data.withUnsafeBytes { raw in Glibc.send(self.fd, raw.baseAddress!.advanced(by: sent), data.count - sent, Int32(MSG_NOSIGNAL)) }
                if n <= 0 { failed = true; break }
                sent += n
            }
            if case .contentProcessed(let done) = completion {
                self.queue.async { done(failed ? NWError.posix(EPIPE) : nil) }
            }
        }
    }

    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping (Data?, Any?, Bool, NWError?) -> Void) {
        reading.async {
            nonisolated(unsafe) var buffer = [UInt8](repeating: 0, count: maximumLength)
            let n = read(self.fd, &buffer, maximumLength)
            self.queue.async {
                if n > 0 {
                    completion(Data(buffer[0..<n]), nil, false, nil)
                } else {
                    completion(nil, nil, true, n < 0 ? NWError.posix(errno) : nil)
                }
            }
        }
    }
}
