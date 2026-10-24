import Foundation

// What WebKit has been asked to make in this process, counted where each
// thing is made. In Chromium mode every count stays at nought: that is the
// whole promise of the engine not chosen costing nothing, and the bench's
// `engine` command is how it is checked rather than believed.
//
// Counted on the main thread, where all of these are made; the counters
// themselves are plain numbers that the bench only reads.

enum Census {
    /// Page views built for tabs (Tab.build).
    nonisolated(unsafe) static var pages = 0
    /// Web view configurations made for tabs (Web.configuration).
    nonisolated(unsafe) static var configurations = 0
    /// Website data stores asked for: the shared one, a space's own, a
    /// private tab's in memory.
    nonisolated(unsafe) static var stores = 0
    /// Times the content blocker's rule list store was asked for (Shield).
    nonisolated(unsafe) static var ruleLists = 0
    /// The extension controller, made once if at all (Extensions).
    nonisolated(unsafe) static var extensions = 0
    /// The process pool every tab shares, made once if at all (Web.pool).
    nonisolated(unsafe) static var pools = 0

    /// For the bench.
    static var counts: [String: Int] {
        ["pageViews": pages, "configurations": configurations, "dataStores": stores,
         "ruleListStores": ruleLists, "extensionControllers": extensions, "processPools": pools]
    }

    /// Whether anything of WebKit's has been made at all.
    static var untouched: Bool { counts.values.allSatisfy { $0 == 0 } }
}
