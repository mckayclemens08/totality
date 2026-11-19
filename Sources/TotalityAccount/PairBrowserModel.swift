import Foundation
import Observation
import Supabase
import TotalityCore

/// A browser waiting to be added, as its slot describes it.
public struct PairingSlot: Sendable, Equatable {
    public let browserPublicKey: Data
    public let deviceLabel: String

    public init(browserPublicKey: Data, deviceLabel: String) {
        self.browserPublicKey = browserPublicKey
        self.deviceLabel = deviceLabel
    }
}

public enum PairingServiceError: Error, Equatable {
    /// No such slot for this account, or it ran out, or it was already filled.
    case gone
    case offline
}

/// The one-time mailbox on the server. It only ever sees public keys and ciphertext.
public protocol BrowserPairingService: Sendable {
    func slot(id: UUID) async throws -> PairingSlot
    func send(_ sealed: BrowserPairing.Sealed, to id: UUID) async throws
}

/// Adding a browser from the iPhone (issue 150): scan its code, check what it says, approve. The content key
/// leaves this phone only sealed to the one browser whose key hash was in the code.
@MainActor
@Observable
public final class PairBrowserModel {
    public enum Phase: Equatable {
        case scanning
        case checking
        /// The browser's name and the six digits that must match the screen it's on.
        case confirming(label: String, code: String)
        case sending
        case done
        case failed(String)
    }

    public private(set) var phase = Phase.scanning
    public static let website = "app.usetotality.com"

    private let service: any BrowserPairingService
    private let rootKey: @Sendable () async throws -> ContentRootKey
    private let keyIsBackedUp: @MainActor () -> Bool
    private var pending: (request: BrowserPairingRequest, slot: PairingSlot)?

    public init(
        service: any BrowserPairingService,
        rootKey: @escaping @Sendable () async throws -> ContentRootKey,
        keyIsBackedUp: @escaping @MainActor () -> Bool
    ) {
        self.service = service
        self.rootKey = rootKey
        self.keyIsBackedUp = keyIsBackedUp
    }

    public func restart() {
        pending = nil
        phase = .scanning
    }

    /// What the camera read. Anything but a Totality code is ignored while scanning, so pointing the
    /// camera at other things does nothing.
    public func scanned(_ text: String) async {
        guard phase == .scanning, let request = BrowserPairingRequest(qr: text) else { return }
        guard keyIsBackedUp() else {
            phase = .failed("Set up your recovery key first. Then your iPhone can add a browser.")
            return
        }
        phase = .checking
        do {
            let slot = try await service.slot(id: request.slotID)
            guard slot.browserPublicKey.count == 32,
                  BrowserPairing.keyHash(browserPublicKey: slot.browserPublicKey) == request.keyHash
            else {
                phase = .failed("This code doesn't match the browser. Nothing was sent. Try a new code.")
                return
            }
            pending = (request, slot)
            phase = .confirming(
                label: slot.deviceLabel,
                code: BrowserPairing.code(slotID: request.slotID, browserPublicKey: slot.browserPublicKey)
            )
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    public func approve() async {
        guard case .confirming = phase, let pending else { return }
        phase = .sending
        do {
            let sealed = try BrowserPairing.seal(
                try await rootKey(), for: pending.request, browserPublicKey: pending.slot.browserPublicKey
            )
            try await service.send(sealed, to: pending.request.slotID)
            self.pending = nil
            phase = .done
        } catch {
            self.pending = nil
            phase = .failed(Self.message(error))
        }
    }

    /// "It's not me": nothing is sent, and the code just runs out.
    public func decline() {
        pending = nil
        phase = .scanning
    }

    private static func message(_ error: Error) -> String {
        switch error as? PairingServiceError {
        case .gone: "That code ran out or was already used. Ask the website for a new one."
        case .offline: "Couldn't reach Totality. Check your connection and try again."
        case nil: "Couldn't add the browser. Nothing was sent."
        }
    }
}

extension SupabaseAccountService: BrowserPairingService {
    private struct SlotRow: Decodable {
        let browser_pub: String
        let device_label: String
    }

    private struct Fill: Encodable {
        let phone_pub: String
        let sealed: String
    }

    public func slot(id: UUID) async throws -> PairingSlot {
        do {
            let rows: [SlotRow] = try await client.from("pairing_slots")
                .select("browser_pub, device_label").eq("id", value: id.uuidString.lowercased()).execute().value
            guard let row = rows.first, let key = Data(hex: row.browser_pub, count: 32) else { throw PairingServiceError.gone }
            return PairingSlot(browserPublicKey: key, deviceLabel: row.device_label)
        } catch let error as PairingServiceError {
            throw error
        } catch {
            throw PairingServiceError.offline
        }
    }

    public func send(_ sealed: BrowserPairing.Sealed, to id: UUID) async throws {
        do {
            let rows: [SlotRow] = try await client.from("pairing_slots")
                .update(Fill(phone_pub: sealed.phonePublicKey.hexString, sealed: sealed.sealed.base64EncodedString()))
                .eq("id", value: id.uuidString.lowercased()).select("browser_pub, device_label").execute().value
            guard !rows.isEmpty else { throw PairingServiceError.gone }
        } catch let error as PairingServiceError {
            throw error
        } catch {
            throw PairingServiceError.offline
        }
    }
}
