import Foundation
import Supabase
import TotalityCore

/// A backup as found on the servers, and whether Supabase's copy is in place.
public struct FetchedBackup: Sendable, Equatable {
    public let backup: KeyBackup
    public let inSupabase: Bool

    public init(backup: KeyBackup, inSupabase: Bool) {
        self.backup = backup
        self.inSupabase = inSupabase
    }
}

/// Where the locked key is kept. Everything here is ciphertext to the servers, because only the
/// recovery key opens it, and that never leaves the person's hands.
public protocol KeyBackupService: Sendable {
    /// The signed-in account, which a device's key gets tied to. Read locally, so it works offline.
    func signedInAccountID() async -> String?
    /// Nil only when both servers answered that there's nothing. Any failure throws, because treating
    /// an outage as "no backup" could lead to a second recovery key over the first.
    func fetchBackup() async throws -> FetchedBackup?
    /// Throws `.backupExists` when another device got there first.
    func saveBackup(_ backup: KeyBackup) async throws
    /// Returns whether Supabase now holds its copy.
    func restoreSupabaseCopy(_ backup: KeyBackup) async -> Bool
    /// Returns whether the Matrix server now holds its copy.
    func copyBackupToMatrix(_ backup: KeyBackup) async -> Bool
}

/// The device's content key, as the app exposes it.
public protocol ContentKeyAccess: Sendable {
    func rootKey() async throws -> ContentRootKey
    func adopt(_ key: ContentRootKey) async throws -> KeyMoveReport
    func keyOwner() async throws -> String?
    func claim(for account: String) async throws
    func settleExistingInstall(signedInAccount: String?) async throws
    func hasSealedContent() async throws -> Bool
    func joinedBackup() async throws -> String?
    func markJoined(_ fingerprint: String) async throws
}

extension SupabaseAccountService: KeyBackupService {
    private struct BackupRow: Codable {
        let key_id: String
        let backup: KeyBackup
    }

    private struct NewBackupRow: Encodable {
        let owner_id: UUID
        let key_id: String
        let backup: KeyBackup
    }

    private struct Pass: Decodable {
        let token: String
    }

    public func signedInAccountID() async -> String? {
        client.auth.currentSession?.user.id.uuidString.lowercased()
    }

    /// Supabase first, because it answers even when the Oracle server is down. A backup with a bad ID
    /// isn't one this app wrote, so it counts as a failure, not as nothing.
    public func fetchBackup() async throws -> FetchedBackup? {
        try await mapErrors {
            let rows: [BackupRow] = try await client.from("key_backups").select("key_id, backup").execute().value
            if let row = rows.first {
                guard row.backup.hasValidID, row.key_id == row.backup.keyID else { throw AccountError.failed }
                return FetchedBackup(backup: row.backup, inSupabase: true)
            }
            guard let backup = try await withMatrix({ try await $0.readBackup() }) else { return nil }
            guard backup.hasValidID else { throw AccountError.failed }
            return FetchedBackup(backup: backup, inSupabase: false)
        }
    }

    public func saveBackup(_ backup: KeyBackup) async throws {
        try await mapErrors {
            let owner = try await client.auth.session.user.id
            do {
                try await client.from("key_backups")
                    .insert(NewBackupRow(owner_id: owner, key_id: backup.keyID, backup: backup))
                    .execute()
            } catch let error as PostgrestError where error.code == "23505" {
                throw AccountError.backupExists
            }
        }
    }

    public func restoreSupabaseCopy(_ backup: KeyBackup) async -> Bool {
        do {
            try await saveBackup(backup)
            return true
        } catch {
            return false
        }
    }

    public func copyBackupToMatrix(_ backup: KeyBackup) async -> Bool {
        do {
            try await withMatrix { try await $0.writeBackup(backup) }
            return true
        } catch {
            return false
        }
    }

    /// A Matrix session lasts for one job and is then thrown away, so no Matrix token is ever stored.
    private func withMatrix<Result: Sendable>(_ work: @Sendable (MatrixSession) async throws -> Result) async throws -> Result {
        let pass: Pass = try await client.functions.invoke("matrix-login", options: FunctionInvokeOptions(method: .post))
        let session = try await MatrixSession.signIn(with: pass.token)
        do {
            let result = try await work(session)
            await session.signOut()
            return result
        } catch {
            await session.signOut()
            throw error
        }
    }
}

/// Just enough of Matrix's client API to read and write account data, in the standard secret storage
/// layout. Private messaging will use a real Matrix SDK when Phase 2 opens.
struct MatrixSession: Sendable {
    static let server = URL(string: "https://matrix.usetotality.com")!
    private static let urlSession = URLSession(configuration: .ephemeral)
    private static let defaultKeyType = "m.secret_storage.default_key"

    private struct Login: Decodable {
        let access_token: String
        let user_id: String
    }

    private struct DefaultKey: Codable {
        let key: String
    }

    private struct KeyDescription: Codable {
        let algorithm: String
        let iv: String
        let mac: String
    }

    private struct SecretContent: Codable {
        let encrypted: [String: LockedSecret.Stored]
    }

    let accessToken: String
    let userID: String

    static func signIn(with pass: String) async throws -> MatrixSession {
        var request = URLRequest(url: server.appendingPathComponent("_matrix/client/v3/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "org.matrix.login.jwt", "token": pass, "initial_device_display_name": "Totality key backup",
        ])
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.failed }
        let login = try JSONDecoder().decode(Login.self, from: data)
        return MatrixSession(accessToken: login.access_token, userID: login.user_id)
    }

    func signOut() async {
        var request = authorized(path: "_matrix/client/v3/logout", method: "POST")
        request.httpBody = Data("{}".utf8)
        _ = try? await Self.urlSession.data(for: request)
    }

    /// Refuses to replace a different backup. It may be the only copy of a key someone still needs.
    func writeBackup(_ backup: KeyBackup) async throws {
        guard backup.hasValidID else { throw AccountError.failed }
        if let current = try await get(DefaultKey.self, type: Self.defaultKeyType), current.key != backup.keyID {
            throw AccountError.backupExists
        }
        try await put(
            KeyDescription(algorithm: KeyBackup.algorithm, iv: backup.check.iv, mac: backup.check.mac),
            type: "m.secret_storage.key.\(backup.keyID)"
        )
        try await put(SecretContent(encrypted: [backup.keyID: .init(backup.secret)]), type: KeyBackup.secretName)
        try await put(DefaultKey(key: backup.keyID), type: Self.defaultKeyType)
    }

    /// Nil only when there's no default key at all. A default key with parts missing means a backup
    /// exists and is damaged, and that must never look like there being no backup. The ID is checked
    /// first, because it's about to go into a URL.
    func readBackup() async throws -> KeyBackup? {
        guard let id = try await get(DefaultKey.self, type: Self.defaultKeyType)?.key else { return nil }
        guard Self.isValidID(id),
              let description = try await get(KeyDescription.self, type: "m.secret_storage.key.\(id)"),
              let secret = try await get(SecretContent.self, type: KeyBackup.secretName)?.encrypted[id]
        else { throw AccountError.failed }
        return KeyBackup(
            keyID: id,
            check: LockedSecret(iv: description.iv, ciphertext: "", mac: description.mac),
            secret: secret.locked
        )
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    private func put(_ value: some Encodable, type: String) async throws {
        var request = authorized(path: accountDataPath(type), method: "PUT")
        request.httpBody = try JSONEncoder().encode(value)
        let (_, response) = try await Self.urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.failed }
    }

    private func get<Value: Decodable>(_ value: Value.Type, type: String) async throws -> Value? {
        let (data, response) = try await Self.urlSession.data(for: authorized(path: accountDataPath(type), method: "GET"))
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(value, from: data)
        case 404: return nil
        default: throw AccountError.failed
        }
    }

    private func accountDataPath(_ type: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let user = userID.addingPercentEncoding(withAllowedCharacters: allowed) ?? userID
        return "_matrix/client/v3/user/\(user)/account_data/\(type)"
    }

    private func authorized(path: String, method: String) -> URLRequest {
        var components = URLComponents(url: Self.server, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/" + path
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

extension LockedSecret {
    /// A locked secret in the shape Matrix account data stores it.
    fileprivate struct Stored: Codable {
        let iv: String
        let ciphertext: String
        let mac: String

        init(_ secret: LockedSecret) {
            iv = secret.iv
            ciphertext = secret.ciphertext
            mac = secret.mac
        }

        var locked: LockedSecret {
            LockedSecret(iv: iv, ciphertext: ciphertext, mac: mac)
        }
    }
}
