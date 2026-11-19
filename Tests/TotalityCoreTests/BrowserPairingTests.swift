import CryptoKit
import Foundation
import Testing
@testable import TotalityCore

/// The same vectors web/site/test/pairing.test.mjs reads, so the iPhone and the website agree byte for byte.
@Suite struct BrowserPairingTests {
    struct Sealed: Decodable { let phonePub: String; let sealed: String? }
    struct Vectors: Decodable {
        let slotId, browserPriv, browserPub, slotSecret, rootKey, keyHash, code, qr, phonePriv: String
        let tsSealed: Sealed
        let swiftSealed: Sealed?
    }

    static let vectors: Vectors = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/pairing-vectors.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: path))
    }()
    let v = BrowserPairingTests.vectors
    var browserPriv: Curve25519.KeyAgreement.PrivateKey { try! .init(rawRepresentation: Data(hex: v.browserPriv, count: 32)!) }
    var slot: UUID { UUID(uuidString: v.slotId)! }

    @Test func readsTheQRAndMatchesTheWebsite() throws {
        let request = try #require(BrowserPairingRequest(qr: v.qr))
        #expect(request.slotID == slot)
        #expect(request.keyHash == v.keyHash)
        let pub = Data(hex: v.browserPub, count: 32)!
        #expect(BrowserPairing.keyHash(browserPublicKey: pub) == v.keyHash)
        #expect(BrowserPairing.code(slotID: slot, browserPublicKey: pub) == v.code)
        #expect(browserPriv.publicKey.rawRepresentation == pub)
    }

    @Test func opensWhatTheWebsiteSealed() throws {
        let request = try #require(BrowserPairingRequest(qr: v.qr))
        let opened = try BrowserPairing.open(
            Data(base64Encoded: v.tsSealed.sealed!)!, slotID: slot, slotSecret: request.slotSecret,
            browserPrivateKey: browserPriv, phonePublicKey: Data(hex: v.tsSealed.phonePub, count: 32)!
        )
        #expect(opened.hexString == v.rootKey)
    }

    @Test func sealsToTheBrowserAndTheWebsiteVectorOpens() throws {
        let request = try #require(BrowserPairingRequest(qr: v.qr))
        let key = try ContentRootKey(bytes: Data(hex: v.rootKey, count: 32)!)
        let out = try BrowserPairing.seal(key, for: request, browserPublicKey: Data(hex: v.browserPub, count: 32)!)
        let opened = try BrowserPairing.open(
            out.sealed, slotID: slot, slotSecret: request.slotSecret, browserPrivateKey: browserPriv, phonePublicKey: out.phonePublicKey
        )
        #expect(opened == key.bytes)
        if let known = v.swiftSealed?.sealed {
            let again = try BrowserPairing.open(
                Data(base64Encoded: known)!, slotID: slot, slotSecret: request.slotSecret,
                browserPrivateKey: browserPriv, phonePublicKey: Data(hex: v.swiftSealed!.phonePub, count: 32)!
            )
            #expect(again == key.bytes)
        } else {
            print("SWIFT-VECTOR", out.phonePublicKey.hexString, out.sealed.base64EncodedString())
        }
    }

    @Test func refusesASwappedBrowserKey() throws {
        let request = try #require(BrowserPairingRequest(qr: v.qr))
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        #expect(throws: PairingError.wrongBrowserKey) {
            try BrowserPairing.seal(try ContentRootKey.generate(), for: request, browserPublicKey: other)
        }
    }

    @Test func refusesBadCodes() {
        let id = UUID().uuidString.lowercased()
        let hex = String(repeating: "a", count: 64)
        for bad in ["", "https://evil.example/x", "totality-pair/2/\(id)/\(hex)/\(hex)", "totality-pair/1/\(id)/zz/\(hex)",
                    "totality-pair/1/\(id)/\(hex)", "totality-pair/1/\(id)/\(hex.uppercased())/\(hex)"] {
            #expect(BrowserPairingRequest(qr: bad) == nil)
        }
    }

    @Test func wrongSlotOrSecretOrTamperingDoesNotOpen() throws {
        let request = try #require(BrowserPairingRequest(qr: v.qr))
        let out = try BrowserPairing.seal(try ContentRootKey.generate(), for: request, browserPublicKey: Data(hex: v.browserPub, count: 32)!)
        for (id, secret) in [(UUID(), request.slotSecret), (slot, Data(repeating: 0, count: 32))] {
            #expect(throws: PairingError.sealFailed) {
                try BrowserPairing.open(out.sealed, slotID: id, slotSecret: secret, browserPrivateKey: browserPriv, phonePublicKey: out.phonePublicKey)
            }
        }
        var tampered = out.sealed
        tampered[40] ^= 1
        #expect(throws: PairingError.sealFailed) {
            try BrowserPairing.open(tampered, slotID: slot, slotSecret: request.slotSecret, browserPrivateKey: browserPriv, phonePublicKey: out.phonePublicKey)
        }
    }
}
