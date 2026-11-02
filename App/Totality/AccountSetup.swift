import TotalityAccount
import TotalityCore

/// Connects sign-in to this device's Keychain. Nil when the build has no backend settings.
@MainActor
enum AccountSetup {
    /// The app's sign-in token for web search, or nil when the build has no backend settings.
    private(set) static var searchToken: (@Sendable () async throws -> String)?

    static func makeModel(content: any ContentKeyAccess) -> AccountModel? {
        guard let config = AccountConfig.fromBundle() else { return nil }
        let service = SupabaseAccountService(
            config: config,
            sessionStore: KeychainKeyStore(service: "app.totality.session"),
            deviceStore: KeychainKeyStore(service: "app.totality.device")
        )
        searchToken = { try await service.accessToken() }
        return AccountModel(
            service: service, backup: BackupModel(service: service, content: content),
            sync: SyncModel(), syncRemote: service.syncRemote
        )
    }
}
