import Foundation
import TotalityCore

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

/// Messages' entry for keeping the chat list fresh before Messages is opened. It reconnects if the
/// connection dropped, and Matrix's own sync does the rest.
public struct MessagesRefresher: ModuleRefresher {
    public let module = ModuleID.messages
    public let kinds: Set<ContentKind> = []
    private let refresh: @Sendable () async -> Void

    public init(refresh: @escaping @Sendable () async -> Void) {
        self.refresh = refresh
    }

    public func refreshAhead() async {
        await refresh()
    }
}

/// Messages in the home search. It reads the chat list already on the device, names only.
public struct MessagesSearcher: ModuleSearcher {
    public let module = ModuleID.messages
    public let kinds: Set<ContentKind> = []
    private let find: @Sendable (String) async -> [SearchHit]

    public init(model: MessagesModel) {
        find = { query in await model.searchHits(query) }
    }

    public func search(_ query: String) async throws -> [SearchHit] { await find(query) }
}
