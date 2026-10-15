import AppKit
import CryptoKit
import LocalAuthentication
import OSLog
import Security

// Passkeys Search keeps itself, for a build without Apple's browser
// entitlement.
//
// The Mac's own passkeys — iCloud Keychain, a password app, a phone over the
// QR code — are reached only through AuthenticationServices' browser API,
// and macOS refuses that API to an app without the entitlement, before any
// sheet: "The calling process does not have an application identifier"
// (AuthorizationError 1004). Apple grants it to a paid developer account
// that asks, for an app id of its own. A build signed by anyone else gets
// nothing from it, and every site's passkey fails.
//
// So such a build is its own authenticator, as a password app is: the key of
// each passkey is made in the Secure Enclave, which never lets it out, and
// may only sign after Touch ID or the Mac's password — the enclave itself
// holds to that, not Search. What Search keeps on disk is the enclave's
// wrapped handle to the key, useless on any other Mac or without your
// finger, beside the site and the account it is for. Sites get a passkey
// like any other: ES256, no attestation, bound to this Mac (never synced,
// so the backup flags stay clear).
//
// They are new passkeys. The ones in iCloud Keychain stay out of reach, so
// an account signs in once some other way and adds one made here.
@MainActor
final class OwnPasskeys {
    static let shared = OwnPasskeys()

    private static let log = Logger(subsystem: "com.officecommun.search", category: "Passkeys")

    /// Where they are said to be kept, under the field.
    static let provider = "Search"

    /// One passkey: the site, the account, and the enclave's handle to its key.
    struct Kept: Codable, Equatable {
        let id: Data
        let rp: String
        let user: Data
        let name: String
        let displayName: String
        let key: Data
        let created: Date
    }

    private static var file: URL { Store.folder.appendingPathComponent("passkeys.json") }

    private(set) var kept: [Kept] = {
        guard let data = try? Data(contentsOf: OwnPasskeys.file) else { return [] }
        return (try? JSONDecoder().decode([Kept].self, from: data)) ?? []
    }()

    private func save() {
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: OwnPasskeys.file, options: .atomic)
    }

    func forget(_ passkey: Kept) {
        kept.removeAll { $0.id == passkey.id }
        save()
    }

    /// Those for a site, the ones it allows if it names any.
    func kept(for rp: String, allowed: Set<Data> = []) -> [Kept] {
        kept.filter { $0.rp == rp && (allowed.isEmpty || allowed.contains($0.id)) }
    }

    /// The same, as the list under the field shows them.
    func offered(for rp: String, allowed: Set<Data>) -> [Passkeys.Offered] {
        kept(for: rp, allowed: allowed).prefix(8).map {
            Passkeys.Offered(id: $0.id, name: $0.name.isEmpty ? "Passkey" : $0.name, provider: OwnPasskeys.provider)
        }
    }

    /// One ceremony at a time; a new one ends the one before.
    private var running: LAContext?
    private var answer: (([String: Any]) -> Void)?
    private var token: String?

    private func begin(_ answer: @escaping ([String: Any]) -> Void, token: String?) -> LAContext {
        if let earlier = self.answer {
            running?.invalidate()
            earlier(OwnPasskeys.failure("NotAllowedError", "A newer request took its place."))
        }
        let context = LAContext()
        running = context
        self.answer = answer
        self.token = token
        return context
    }

    private func finish(_ context: LAContext, _ value: [String: Any]) {
        guard context === running else { return }
        let answer = self.answer
        running = nil
        self.answer = nil
        token = nil
        answer?(value)
    }

    /// Called off by its page.
    func cancel(token: String?) {
        guard let running, let token, token == self.token else { return }
        running.invalidate()
        finish(running, OwnPasskeys.failure("AbortError", "The operation was aborted."))
    }

    // MARK: - a site makes one

    func create(_ body: [String: Any], rp: String, origin: String, challenge: Data, answer: @escaping ([String: Any]) -> Void) {
        guard let user = body["user"] as? [String: Any],
              let userID = Passkeys.data(user["id"]), (1...64).contains(userID.count),
              let name = user["name"] as? String
        else { return answer(OwnPasskeys.failure("TypeError", "The request names no user, or one too long.")) }
        let algorithms = (body["algorithms"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? [-7, -257]
        guard algorithms.contains(-7), body["authenticatorAttachment"] as? String != "cross-platform" else {
            return answer(OwnPasskeys.failure("NotSupportedError", "No authenticator here can make that kind of key."))
        }
        let excluded = Set(Passkeys.data(list: body["excludeCredentials"]))
        if kept(for: rp).contains(where: { excluded.contains($0.id) }) {
            return answer(OwnPasskeys.failure("InvalidStateError", "The authenticator already holds a credential for this account."))
        }
        let display = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let context = begin(answer, token: body["token"] as? String)
        let label = name.isEmpty ? rp : "\(name) on \(rp)"
        Task { @MainActor in
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "make a passkey for \(label)")
                guard let access = OwnPasskeys.access() else { throw OwnPasskeys.Failure.enclave }
                let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
                var id = Data(count: 32)
                _ = id.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                // A new one for the same account takes the old one's place, as
                // a site's own list of keys for you would have it.
                self.kept.removeAll { $0.rp == rp && $0.user == userID }
                self.kept.append(Kept(id: id, rp: rp, user: userID, name: String(name.prefix(200)),
                                      displayName: String(display.prefix(200)), key: key.dataRepresentation, created: Date()))
                self.save()
                OwnPasskeys.log.notice("made one of Search's own for \(rp, privacy: .public)")

                let client = OwnPasskeys.clientData("webauthn.create", challenge: challenge, origin: origin)
                let auth = OwnPasskeys.authenticatorData(rp: rp, flags: 0x45) + OwnPasskeys.attested(id: id, key: key.publicKey)
                let reply = Passkeys.registrationReply(id: id, clientData: client, attestation: OwnPasskeys.attestationObject(auth),
                                                       transports: ["internal"], attachment: "platform")
                self.finish(context, reply)
            } catch {
                OwnPasskeys.log.notice("didn't make one: \(String(describing: error), privacy: .public)")
                self.finish(context, OwnPasskeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
            }
        }
    }

    // MARK: - a site asks for one

    /// `only`: the passkey picked under the field, if one was.
    func get(_ body: [String: Any], rp: String, origin: String, challenge: Data, only: Data? = nil,
             in window: NSWindow?, answer: @escaping ([String: Any]) -> Void) {
        let allowed = Set(Passkeys.data(list: body["allowCredentials"]))
        var choices = kept(for: rp, allowed: allowed)
        if let only { choices = choices.filter { $0.id == only } }
        guard !choices.isEmpty else {
            OwnPasskeys.none(for: rp, in: window)
            return answer(OwnPasskeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
        }
        guard let chosen = choices.count == 1 ? choices[0] : OwnPasskeys.pick(choices, for: rp, in: window) else {
            return answer(OwnPasskeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
        }
        let context = begin(answer, token: body["token"] as? String)
        let label = chosen.name.isEmpty ? rp : "\(chosen.name) on \(rp)"
        Task { @MainActor in
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sign in as \(label)")
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: chosen.key, authenticationContext: context)
                let client = OwnPasskeys.clientData("webauthn.get", challenge: challenge, origin: origin)
                let auth = OwnPasskeys.authenticatorData(rp: rp, flags: 0x05)
                let signature = try key.signature(for: auth + Data(SHA256.hash(data: client)))
                OwnPasskeys.log.notice("signed in with one of Search's own for \(rp, privacy: .public)")
                self.finish(context, Passkeys.assertionReply(id: chosen.id, clientData: client, authenticatorData: auth,
                                                             signature: signature.derRepresentation, user: chosen.user,
                                                             attachment: "platform"))
            } catch {
                OwnPasskeys.log.notice("didn't sign: \(String(describing: error), privacy: .public)")
                self.finish(context, OwnPasskeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
            }
        }
    }

    // MARK: - asking you

    /// Which account, when the site has more than one passkey here.
    private static func pick(_ choices: [Kept], for rp: String, in window: NSWindow?) -> Kept? {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(rp)"
        alert.informativeText = "Choose the account to use its passkey."
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for choice in choices {
            menu.addItem(withTitle: choice.name.isEmpty ? choice.displayName : choice.name)
        }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return choices[menu.indexOfSelectedItem]
    }

    /// Asked for a passkey Search doesn't have: why, and what to do, rather
    /// than the site's "something went wrong".
    private static func none(for rp: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "No passkey for \(rp) in Search"
        alert.informativeText = "This copy of Search can't use your iCloud passkeys. Sign in another way, then add a passkey in the site's security settings: Search will keep it on this Mac, opened with Touch ID."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - bytes

    private enum Failure: Error { case enclave }

    /// Only after Touch ID or the Mac's password, and only on this Mac.
    /// "After first unlock" rather than "when unlocked": the enclave asks for
    /// you each time regardless, and a key made while the screen is locked
    /// would otherwise fail to be made at all.
    private static func access() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
    }

    private static func failure(_ name: String, _ message: String) -> [String: Any] {
        ["error": name, "message": message]
    }

    /// Written here, from the origin WebKit reports for the frame — never one
    /// the page states — in the order the standard gives.
    static func clientData(_ type: String, challenge: Data, origin: String) -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(Passkeys.text(challenge))","origin":"\#(origin)","crossOrigin":false}"#.utf8)
    }

    /// The site's hash, the flags — present, verified, and with a new key
    /// when 0x40 — and a count that stays at zero, as passkeys' do.
    static func authenticatorData(rp: String, flags: UInt8) -> Data {
        Data(SHA256.hash(data: Data(rp.utf8))) + Data([flags]) + Data(count: 4)
    }

    /// A new key's part of it: no model to vouch for (zero AAGUID), its id,
    /// and its public half as COSE: EC2, ES256, P-256, x, y.
    static func attested(id: Data, key: P256.Signing.PublicKey) -> Data {
        let raw = key.rawRepresentation
        var data = Data(count: 16) + Data([UInt8(id.count >> 8), UInt8(id.count & 0xFF)]) + id
        data += Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + raw.prefix(32)
        data += Data([0x22, 0x58, 0x20]) + raw.suffix(32)
        return data
    }

    /// {"fmt": "none", "attStmt": {}, "authData": …}, the byte string's
    /// length in the shortest form, as strict readers want it.
    static func attestationObject(_ auth: Data) -> Data {
        var object = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        object += Data([0x67]) + Data("attStmt".utf8) + Data([0xA0])
        object += Data([0x68]) + Data("authData".utf8)
        switch auth.count {
        case ..<24: object += Data([0x40 | UInt8(auth.count)])
        case ..<256: object += Data([0x58, UInt8(auth.count)])
        default: object += Data([0x59, UInt8(auth.count >> 8), UInt8(auth.count & 0xFF)])
        }
        return object + auth
    }
}

extension Passkeys {
    /// The ids in a page's allowCredentials or excludeCredentials.
    static func data(list value: Any?) -> [Data] {
        (value as? [[String: Any]] ?? []).compactMap { data($0["id"]) }
    }
}
