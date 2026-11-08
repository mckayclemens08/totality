import Foundation

public enum MessagesModule {
    /// The Messages model for this build. `account` is the signed-in Totality account's ID, and
    /// `connector` opens a connection for it. Nil without backend settings, or where the Matrix SDK
    /// isn't linked, which `unavailableReason` then explains.
    @MainActor
    public static func makeModel(
        account: (@Sendable () async -> String?)?,
        connector: MessagesConnector?,
        unavailableReason: String? = nil
    ) -> MessagesModel {
        guard let account else { return MessagesModel(account: { nil }, connector: nil) }
        return MessagesModel(account: account, connector: connector, unavailableReason: connector == nil ? unavailableReason : nil)
    }
}
