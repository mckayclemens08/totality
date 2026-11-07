import Foundation
import Observation
import TotalityCore

// Step 1 of the Messages spec (issue 51): a trial, never merged. It signs in to the Matrix server with
// the one-minute pass, keeps the SDK's stores per account in the app's container, and sends one
// end-to-end encrypted message to another Totality account.

/// One line the trial screen shows. `decrypted` is false when the SDK couldn't open the message.
public struct TrialMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let sender: String
    public let body: String
    public let decrypted: Bool
    public let isOwn: Bool
}

/// Where the SDK keeps an account's session and crypto stores, inside the app's own container.
/// Each Totality account gets its own folder, so a second account on the device starts from nothing.
public struct MessagesStorePaths: Sendable {
    public let data: URL
    public let cache: URL

    public init(account: String, fileManager: FileManager = .default) throws {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        data = support.appendingPathComponent("Messages/\(account)", isDirectory: true)
        cache = caches.appendingPathComponent("Messages/\(account)", isDirectory: true)
        for folder in [data, cache] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The stores are encrypted with a key from the Keychain, and the Keychain stays on this device,
        // so a device backup of the folder alone would be useless. Leave it out of backups anyway.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = data
        try? marked.setResourceValues(values)
    }
}

@MainActor
@Observable
public final class MessagesTrialModel {
    public enum Phase: Equatable, Sendable {
        case signedOut
        case connecting
        case ready(userID: String, deviceID: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .signedOut
    public private(set) var messages: [TrialMessage] = []
    public private(set) var status: String?
    public private(set) var storeFolder: String?

    /// The signed-in Totality account's ID, used for the store folder and Keychain names.
    let account: @Sendable () async -> String?
    /// The one-minute Matrix pass from the account server.
    let pass: @Sendable () async throws -> String
    let keys: any KeyStore

    #if canImport(MatrixRustSDK)
    private var engine: MatrixEngine?
    #endif

    public init(
        account: @escaping @Sendable () async -> String?,
        pass: @escaping @Sendable () async throws -> String,
        keys: any KeyStore = KeychainKeyStore(service: "app.totality.messages")
    ) {
        self.account = account
        self.pass = pass
        self.keys = keys
    }

    public static var isAvailable: Bool {
        #if canImport(MatrixRustSDK)
        true
        #else
        false
        #endif
    }

    public func connect() async {
        #if canImport(MatrixRustSDK)
        guard engine == nil else { return }
        guard let account = await account() else {
            phase = .failed("Sign in to Totality first.")
            return
        }
        phase = .connecting
        do {
            let paths = try MessagesStorePaths(account: account)
            storeFolder = paths.data.path
            let engine = try await MatrixEngine.open(account: account, paths: paths, keys: keys, pass: pass) { [weak self] messages in
                Task { @MainActor in self?.messages = messages }
            }
            self.engine = engine
            phase = .ready(userID: engine.userID, deviceID: engine.deviceID)
        } catch {
            phase = .failed(MatrixEngine.describe(error))
        }
        #else
        phase = .failed("Messages needs the Matrix SDK, which has no Mac build yet.")
        #endif
    }

    /// Finds or makes an encrypted direct chat with that username, and sends the text there.
    public func send(_ text: String, to username: String) async {
        #if canImport(MatrixRustSDK)
        guard let engine else { return }
        // Someone may type the @ anyway, or paste a name with spaces around it.
        let username = String(username.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "@" }).lowercased()
        // The same rule usernames are claimed under: 3 to 24 letters, digits, or underscores.
        guard username.wholeMatch(of: /[a-z0-9_]{3,24}/) != nil else {
            status = "That isn't a Totality username."
            return
        }
        status = "Sending…"
        do {
            try await engine.send(text, to: username)
            status = "Sent to @\(username)."
        } catch {
            status = "Couldn't send: \(MatrixEngine.describe(error))"
        }
        #endif
    }
}
