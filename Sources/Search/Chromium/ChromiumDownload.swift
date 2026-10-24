import CryptoKit
import Foundation

// The add-on's download, done as the AI engine's is (AIDownload in
// AIEngine.swift): secure addresses only, redirects included; room for it
// on the disk first; never more than the feed said; and the exact size and
// SHA-256 checked before anything is done with it. Nothing of yours is
// sent along.

enum ChromiumDownload {
    struct Failure: LocalizedError {
        let why: String
        init(_ why: String) { self.why = why }
        var errorDescription: String? { why }
    }

    @MainActor
    static func fetch(_ url: URL, size: Int64, sha256: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw Failure("Not a secure address.") }
        let folder = ChromiumAddon.folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The zip, and what it unpacks to beside it: a little over three
        // times its size until the zip goes.
        let needed = size * 4
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw Failure("There isn't enough free space on this Mac (\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed).")
        }
        let watcher = Watcher(progress: progress, size: size)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3 * 3600
        let session = URLSession(configuration: configuration, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url, delegate: watcher)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure("The download was refused.")
        }
        let file = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: file)
        let matches = await Task.detached(priority: .utility) { () -> Bool in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
            return total == size && hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
        }.value
        guard matches else {
            try? FileManager.default.removeItem(at: file)
            throw Failure("What arrived isn't what was expected, so it was deleted.")
        }
        return file
    }

    /// Progress, and only secure addresses followed. What arrives is judged
    /// by its hash, not by where it came from.
    private final class Watcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @MainActor (Double) -> Void
        let size: Int64
        init(progress: @escaping @MainActor (Double) -> Void, size: Int64) {
            self.progress = progress
            self.size = size
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let done = Double(totalBytesWritten) / Double(max(1, size))
            let report = progress
            Task { @MainActor in report(min(1, done)) }
            if totalBytesWritten > size + 1024 { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }
}
