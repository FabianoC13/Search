@_exported import Foundation
@_exported import FoundationNetworking
#if canImport(Glibc)
import Glibc
#endif

// What the bridge uses of AppKit, for a harness on Linux.
open class NSApplication {
    public func terminate(_ sender: Any?) { exit(0) }
}
nonisolated(unsafe) public let NSApp = NSApplication()
