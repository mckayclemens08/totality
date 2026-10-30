import TotalityAccount
import TotalityCore

/// Connects sign-in to this device's Keychain. Nil when the build has no backend settings.
@MainActor
enum AccountSetup {
    static func makeModel() -> AccountModel? {
        guard let config = AccountConfig.fromBundle() else { return nil }
        let service = SupabaseAccountService(
            config: config,
            sessionStore: KeychainKeyStore(service: "app.totality.session"),
            deviceStore: KeychainKeyStore(service: "app.totality.device")
        )
        return AccountModel(service: service)
    }
}
