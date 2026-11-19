import CryptoKit
import Foundation
import Testing
import TotalityCore
@testable import TotalityAccount

private actor FakePairing: BrowserPairingService {
    var slot: PairingSlot
    var sent: [(BrowserPairing.Sealed, UUID)] = []
    var gone = false
    init(slot: PairingSlot) { self.slot = slot }
    func slot(id: UUID) async throws -> PairingSlot {
        if gone { throw PairingServiceError.gone }
        return slot
    }
    func send(_ sealed: BrowserPairing.Sealed, to id: UUID) async throws {
        if gone { throw PairingServiceError.gone }
        sent.append((sealed, id))
    }
    func setSlot(_ new: PairingSlot) { slot = new }
    func expire() { gone = true }
}

@MainActor
@Suite struct PairBrowserTests {
    let browser = Curve25519.KeyAgreement.PrivateKey()
    let slotSecret = Data((0..<32).map { UInt8($0) })
    let id = UUID()

    private func qr(for key: Data) -> String {
        "totality-pair/1/\(id.uuidString.lowercased())/\(slotSecret.hexString)/\(BrowserPairing.keyHash(browserPublicKey: key))"
    }

    private func model(_ service: FakePairing, backedUp: Bool = true) throws -> PairBrowserModel {
        let key = try ContentRootKey.generate()
        return PairBrowserModel(service: service, rootKey: { key }, keyIsBackedUp: { backedUp })
    }

    @Test func scansChecksAndOnlyThenSends() async throws {
        let pub = browser.publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: pub, deviceLabel: "Safari on a Mac"))
        let m = try model(service)
        await m.scanned(qr(for: pub))
        let code = BrowserPairing.code(slotID: id, browserPublicKey: pub)
        #expect(m.phase == PairBrowserModel.Phase.confirming(label: "Safari on a Mac", code: code))
        let none = await service.sent.isEmpty
        #expect(none)
        await m.approve()
        #expect(m.phase == PairBrowserModel.Phase.done)
        let count = await service.sent.count
        #expect(count == 1)
    }

    @Test func aSwappedBrowserKeyIsRefusedAndNothingIsSent() async throws {
        let attacker = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: attacker, deviceLabel: "Safari on a Mac"))
        let m = try model(service)
        await m.scanned(qr(for: browser.publicKey.rawRepresentation))
        guard case .failed = m.phase else { Issue.record("should have failed"); return }
        await m.approve()
        let none = await service.sent.isEmpty
        #expect(none)
    }

    @Test func withoutARecoveryKeyNothingIsSent() async throws {
        let pub = browser.publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: pub, deviceLabel: "x"))
        let m = try model(service, backedUp: false)
        await m.scanned(qr(for: pub))
        guard case .failed = m.phase else { Issue.record("should have failed"); return }
        let none = await service.sent.isEmpty
        #expect(none)
    }

    @Test func declineSendsNothing() async throws {
        let pub = browser.publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: pub, deviceLabel: "x"))
        let m = try model(service)
        await m.scanned(qr(for: pub))
        m.decline()
        await m.approve()
        #expect(m.phase == PairBrowserModel.Phase.scanning)
        let none = await service.sent.isEmpty
        #expect(none)
    }

    @Test func otherQRCodesAreIgnoredAndAnExpiredSlotFails() async throws {
        let pub = browser.publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: pub, deviceLabel: "x"))
        let m = try model(service)
        await m.scanned("https://example.com")
        #expect(m.phase == PairBrowserModel.Phase.scanning)
        await service.expire()
        await m.scanned(qr(for: pub))
        guard case .failed = m.phase else { Issue.record("should have failed"); return }
    }

    @Test func whatIsSentIsOnlyCiphertextAndAPublicKey() async throws {
        let pub = browser.publicKey.rawRepresentation
        let service = FakePairing(slot: PairingSlot(browserPublicKey: pub, deviceLabel: "x"))
        let key = try ContentRootKey.generate()
        let m = PairBrowserModel(service: service, rootKey: { key }, keyIsBackedUp: { true })
        await m.scanned(qr(for: pub))
        await m.approve()
        let (sealed, sentTo) = try #require(await service.sent.first)
        #expect(sentTo == id)
        let expected = 73
        #expect(sealed.sealed.count == expected)
        #expect(sealed.phonePublicKey.count == 32)
    }
}
