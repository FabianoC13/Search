import CryptoKit
import Foundation
import XCTest
@testable import Search

/// The bytes Search's own passkeys hand a site, read back the way a site
/// reads them: a software key stands in for the Secure Enclave's, which a
/// test can't touch without Touch ID.
@MainActor
final class OwnPasskeysTests: XCTestCase {
    func testRegistrationReadsBackAsAnES256KeyForTheSite() throws {
        let key = P256.Signing.PrivateKey()
        let id = Data((0..<32).map { UInt8($0) })
        let auth = OwnPasskeys.authenticatorData(rp: "example.com", flags: 0x45) + OwnPasskeys.attested(id: id, key: key.publicKey)
        let object = OwnPasskeys.attestationObject(auth)

        // {"fmt": "none", "attStmt": {}, "authData": bytes of one-byte length}
        XCTAssertEqual(object.prefix(2), Data([0xA3, 0x63]))
        let tail = object.suffix(auth.count + 2)
        XCTAssertEqual(tail.prefix(2), Data([0x58, UInt8(auth.count)]))

        let read = try XCTUnwrap(Passkeys.authenticatorData(inAttestation: object))
        XCTAssertEqual(read, auth)
        XCTAssertEqual(read.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertEqual(read[32], 0x45)
        XCTAssertEqual(read[53...54], Data([0, 32]))
        XCTAssertEqual(read[55..<87], id)

        let found = try XCTUnwrap(Passkeys.publicKey(inAuthenticatorData: read))
        XCTAssertEqual(found.algorithm, -7)
        let der = try XCTUnwrap(found.der)
        XCTAssertEqual(try P256.Signing.PublicKey(derRepresentation: der).rawRepresentation, key.publicKey.rawRepresentation)
    }

    func testAssertionSignatureVerifiesOverAuthenticatorDataAndClientDataHash() throws {
        let key = P256.Signing.PrivateKey()
        let challenge = Data([1, 2, 3, 250, 251, 252])
        let client = OwnPasskeys.clientData("webauthn.get", challenge: challenge, origin: "https://login.example.com")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: client) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "webauthn.get")
        XCTAssertEqual(parsed["challenge"] as? String, Passkeys.text(challenge))
        XCTAssertEqual(parsed["origin"] as? String, "https://login.example.com")
        XCTAssertEqual(parsed["crossOrigin"] as? Bool, false)

        let auth = OwnPasskeys.authenticatorData(rp: "example.com", flags: 0x05)
        XCTAssertEqual(auth.count, 37)
        let signed = auth + Data(SHA256.hash(data: client))
        let signature = try key.signature(for: signed).derRepresentation
        // What a site does with it.
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: signed))

        let reply = Passkeys.assertionReply(id: Data([9, 9]), clientData: client, authenticatorData: auth,
                                            signature: signature, user: Data("u".utf8), attachment: "platform")
        XCTAssertEqual(Passkeys.data(reply["signature"]), signature)
        XCTAssertEqual(Passkeys.data(reply["authenticatorData"]), auth)
    }

    func testIdsAreReadFromAllowAndExcludeLists() {
        let list: [[String: Any]] = [["type": "public-key", "id": Passkeys.text(Data([1, 2]))], ["type": "public-key"]]
        XCTAssertEqual(Passkeys.data(list: list), [Data([1, 2])])
        XCTAssertEqual(Passkeys.data(list: nil), [])
    }
}
