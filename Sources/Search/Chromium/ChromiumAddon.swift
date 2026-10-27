import CChromium
import Foundation
import Security

// Chromium is not in Search: a browser of three megabytes stays one for
// everybody who never turns it on. It is an add-on, downloaded on request:
// CEF's framework and the helper app Chromium starts its other processes
// from, side by side in Store.folder/Chromium/<version>/ (chromium.sh
// makes it). The updater replaces the app and leaves that folder alone, so
// the add-on outlives updates — until an update pins another version.
//
// Only one version can run: the one whose C API the app was compiled
// against (CChromium's headers say which). An offer of any other is not
// an offer.
//
// Nothing downloaded is taken on trust. The zip's hash is the signed
// feed's; what it unpacks to must hold no links, and the framework and the
// helper must hold up under the strict check, nested code included, signed
// by the team that signed Search — checked again at every launch, before
// anything of it is loaded. A Search signed ad hoc (a development build)
// has no team to compare with, and accepts any signature that holds up:
// its own changes with every build, and it loads the framework without
// library validation anyway.

/// The add-on: Chromium's framework and its helper app, kept in
/// Store.folder/Chromium/<version>/, outside the app, so Search stays small
/// for everyone who never turns Chromium on.
@MainActor
final class ChromiumAddon: ObservableObject {
    static let shared = ChromiumAddon()

    enum State: Equatable {
        case absent
        /// Not offered by the feed yet, and nothing installed.
        case unavailable
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    /// What the update feed offers: json["chromium"] in appcast.json, read
    /// by Updater, which checks the address the same way as the AI engine's.
    struct Offer: Equatable {
        let version: String
        let url: URL
        let sha256: String
        let size: Int64
    }
    var offered: Offer? {
        didSet { if offered != oldValue { refresh() } }
    }

    @Published private(set) var state: State = .absent
    /// The download's size in bytes when the feed offers one.
    var size: Int64? { usable?.size }
    /// The Chromium version installed, or offered.
    var version: String? { installed != nil ? ChromiumAddon.pinned : usable?.version }

    /// The one version this build runs: the CEF its headers came from, such
    /// as "156.0.8+g426920c+chromium-156.0.8078.48". Also the folder's name.
    nonisolated static let pinned = String(cString: chromium_pinned_version())
    /// Downloads larger than this are refused whatever the feed says; the
    /// add-on is about 150 MB zipped.
    nonisolated static let cap: Int64 = 400 << 20
    nonisolated static let helperIdentifier = "com.officecommun.search.helper"

    // MARK: - Where

    nonisolated static var folder: URL { Store.folder.appendingPathComponent("Chromium", isDirectory: true) }
    nonisolated static var home: URL { (Launch.active ? installedFolder : folder).appendingPathComponent(pinned, isDirectory: true) }
    /// Where the add-on of the Search you use lives. A run Playwright started
    /// keeps everything in a folder of its own (Launch.swift), and reads the
    /// add-on from yours.
    nonisolated static var installedFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Store.beta ? "Search Beta" : "Search", isDirectory: true)
            .appendingPathComponent("Chromium", isDirectory: true)
    }
    nonisolated static func framework(in home: URL) -> URL {
        home.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
    }
    nonisolated static func binary(in home: URL) -> URL {
        framework(in: home).appendingPathComponent("Chromium Embedded Framework")
    }
    /// The helper's executable; Chromium starts every other process from it.
    nonisolated static func helper(in home: URL) -> URL {
        home.appendingPathComponent("Search Helper.app/Contents/MacOS/Search Helper")
    }

    /// The add-on's folder, when everything Chromium needs is in it. Not yet
    /// checked: that is `trust`.
    var installed: URL? {
        let home = ChromiumAddon.home
        let files = FileManager.default
        guard files.fileExists(atPath: ChromiumAddon.binary(in: home).path),
              files.isExecutableFile(atPath: ChromiumAddon.helper(in: home).path)
        else { return nil }
        return home
    }

    /// The offer, if it is one this build can use.
    private var usable: Offer? {
        guard let offer = offered, offer.version == ChromiumAddon.pinned,
              offer.size > 0, offer.size <= ChromiumAddon.cap
        else { return nil }
        return offer
    }

    private init() {
        refresh()
    }

    /// The state, from what is on disk and what is offered. A failure stays
    /// until somebody tries again, or the add-on turns up.
    func refresh() {
        switch state {
        case .downloading, .installing:
            return
        case .failed where installed == nil:
            return
        default:
            state = installed != nil ? .ready : usable != nil ? .absent : .unavailable
        }
    }

    // MARK: - Installing

    private var installing: Task<Void, Never>?

    func install() {
        guard installing == nil, let offer = usable else { return }
        state = .downloading(0)
        installing = Task { @MainActor in
            defer { installing = nil }
            do {
                let zip = try await ChromiumDownload.fetch(offer.url, size: offer.size, sha256: offer.sha256) { done in
                    guard case .downloading = self.state else { return }
                    self.state = .downloading(done)
                }
                try Task.checkCancellation()
                state = .installing
                try await Task.detached(priority: .userInitiated) {
                    try ChromiumAddon.place(zip, version: offer.version)
                }.value
                state = .ready
            } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = installed != nil ? .ready : .absent
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        installing?.cancel()
    }

    /// Deletes the add-on, every version of it. Not the profile: switching
    /// back later finds its sign-ins where they were. Not while Chromium
    /// runs from it, either — that waits for a launch that doesn't.
    func remove() {
        guard !ChromiumRuntime.running else { return }
        installing?.cancel()
        ChromiumAddon.sweep(keeping: nil)
        try? FileManager.default.removeItem(at: ChromiumAddon.folder.appendingPathComponent("Downloads"))
        state = .absent
        refresh()
    }

    /// Unpacks a checked download into a folder beside the add-on's, checks
    /// what came out, and moves it into place. Off the main thread. The zip
    /// is deleted whatever happens.
    nonisolated static func place(_ zip: URL, version: String) throws {
        let files = FileManager.default
        defer { try? files.removeItem(at: zip) }
        let staging = folder.appendingPathComponent("Staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        // ditto, as Archive Utility does it. Search declares no file
        // quarantine, so nothing it downloads is flagged: the checking is
        // done here, not by Gatekeeper.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ChromiumDownload.Failure("The download didn't unpack.") }

        let unpacked = staging.appendingPathComponent(version, isDirectory: true)
        guard files.fileExists(atPath: binary(in: unpacked).path) else {
            throw ChromiumDownload.Failure("The download isn't the Chromium it said it was.")
        }
        // A link could point anywhere at all; the add-on has none.
        let walker = files.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = walker?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw ChromiumDownload.Failure("The download holds a link, so it was deleted.")
            }
        }
        if let why = trust(unpacked) { throw ChromiumDownload.Failure(why) }

        let target = folder.appendingPathComponent(version, isDirectory: true)
        try? files.removeItem(at: target)
        try files.moveItem(at: unpacked, to: target)
        sweep(keeping: version)
    }

    /// Older versions, and anything a stopped install left, go; the profile
    /// and the log stay. Nil keeps no version at all.
    nonisolated private static func sweep(keeping version: String?) {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where name != version && (name.contains("+chromium-") || name.hasPrefix("Staging-")) {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - Checking

    /// Nil when the add-on in `home` can be loaded; otherwise why not, in
    /// words for Settings.
    nonisolated static func trust(_ home: URL) -> String? {
        let team = team()
        let parts: [(file: URL, name: String, identifier: String?)] = [
            (framework(in: home), "Chromium's framework", nil),
            (home.appendingPathComponent("Search Helper.app", isDirectory: true), "Chromium's helper", helperIdentifier),
        ]
        for part in parts {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(part.file as CFURL, [], &code) == errSecSuccess, let code else {
                return "\(part.name) isn't signed."
            }
            var clauses: [String] = []
            if let identifier = part.identifier { clauses.append("identifier \"\(identifier)\"") }
            // Apple's chain, to this team: Developer ID and development
            // certificates alike, as library validation will judge it.
            if let team { clauses.append("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"") }
            var requirement: SecRequirement?
            if !clauses.isEmpty,
               SecRequirementCreateWithString(clauses.joined(separator: " and ") as CFString, [], &requirement) != errSecSuccess {
                return "\(part.name) can't be checked."
            }
            let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
            guard SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else {
                return team == nil
                    ? "\(part.name)'s signature doesn't hold up."
                    : "\(part.name) isn't signed by the team that signed Search."
            }
        }
        return nil
    }

    /// The team that signed this Search, as the system reads it; nil when
    /// it was signed ad hoc.
    nonisolated static func team() -> String? {
        var running: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
