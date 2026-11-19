import TotalityAccount
import TotalityCore
import TotalityMessages

/// Connects sign-in to this device's Keychain. Nil when the build has no backend settings.
@MainActor
enum AccountSetup {
    /// The app's sign-in token for web search, or nil when the build has no backend settings.
    private(set) static var searchToken: (@Sendable () async throws -> String)?
    /// The signed-in username, which is also the mail address's first half.
    private(set) static var username: (@Sendable () async -> String?)?
    /// The one-minute Matrix pass for Messages, and the account its stores belong to.
    private(set) static var matrixPass: (@Sendable () async throws -> String)?
    private(set) static var accountID: (@Sendable () async -> String?)?
    /// Where one account's photos keep their rows, and the sealed store's sign-in for that account.
    private(set) static var photoRows: ((String) -> SupabasePhotoRows)?
    /// What locks Messages' key backup: derived from the content key, and only once that key is the
    /// account's backed-up one, which the recovery key restores. Never from the password.
    private(set) static var messagesRecovery: (@Sendable (String) async -> String?)?
    /// How much of the account's sealed storage is used, of how much.
    private(set) static var storageUsage: (@Sendable () async throws -> SealedStoreUsage)?
    /// Other people's public profiles, which Messages reaches through the `ModuleRegistry`.
    private(set) static var profiles: (any ProfileDirectory)?
    /// Where Social's public side is: the backend and its publishable key, never a secret.
    private(set) static var config: AccountConfig?

    static func makeModel(content: any ContentKeyAccess) -> AccountModel? {
        guard let config = AccountConfig.fromBundle() else { return nil }
        self.config = config
        let service = SupabaseAccountService(
            config: config,
            sessionStore: KeychainKeyStore(service: "app.totality.session"),
            deviceStore: KeychainKeyStore(service: "app.totality.device")
        )
        searchToken = { try await service.accessToken() }
        username = { await service.currentUsername() }
        matrixPass = { try await service.matrixPass() }
        accountID = { await service.signedInAccountID() }
        photoRows = { service.photoRows(for: $0) }
        let sealedStore = SealedStoreClient(token: { try await service.accessToken() })
        storageUsage = { try await sealedStore.usage() }
        profiles = service
        messagesRecovery = { account in
            let joined = (try? await content.joinedBackup()) != nil
            let owner = try? await content.keyOwner()
            guard RecoverySecretRule.allows(keyOwner: owner, account: account, joinedBackup: joined),
                  let key = try? await content.rootKey() else { return nil }
            return key.matrixRecoverySecret()
        }
        let backup = BackupModel(service: service, content: content)
        let model = AccountModel(service: service, backup: backup, sync: SyncModel(), syncRemote: service.syncRemote)
        // A browser is only ever given a key the recovery key can also restore.
        model.pairing = PairBrowserModel(
            service: service, rootKey: { try await content.rootKey() },
            keyIsBackedUp: { if case .ready = backup.phase { true } else { false } }
        )
        model.browsers = BrowsersModel(service: service)
        return model
    }

    /// Messages for whoever is signed in. The Matrix SDK is linked for iPhone only.
    static func makeMessages() -> MessagesModel {
        #if canImport(MatrixRustSDK)
        var connector: MessagesConnector?
        if let pass = matrixPass {
            connector = { account in try await MatrixMessagesService.connect(account: account, pass: pass) }
        }
        let recovery: @Sendable (String) async -> String? = { account in
            let secret = await MainActor.run { AccountSetup.messagesRecovery }
            return await secret?(account)
        }
        return MessagesModule.makeModel(account: accountID, connector: connector, recoverySecret: recovery)
        #else
        return MessagesModule.makeModel(
            account: accountID, connector: nil,
            unavailableReason: "Messages runs in the iPhone app. Open Totality's iPhone version on this Mac to use it."
        )
        #endif
    }
}
