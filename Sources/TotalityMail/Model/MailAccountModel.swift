import Foundation
import Observation
import TotalityCore

/// Mail for whoever owns this device's key. A mailbox belongs to one account and one key, so a change
/// of either starts a new model on a new store, and nothing of the last person's mail stays on screen,
/// in memory, or waiting to be saved.
@MainActor
@Observable
public final class MailAccountModel {
    public private(set) var current: MailModel
    @ObservationIgnored public private(set) var account: String?
    /// Where attachments are saved. It comes with the key and goes with it.
    @ObservationIgnored public var receiver: (any ContentReceiver)? {
        didSet { current.receiver = receiver }
    }
    @ObservationIgnored public var onSentToReader: (() -> Void)? {
        didSet { current.onSentToReader = onSentToReader }
    }
    @ObservationIgnored private let makeStore: (String?) -> any MailStore

    public init(makeStore: @escaping (String?) -> any MailStore) {
        self.makeStore = makeStore
        current = MailModel(store: makeStore(nil))
    }

    /// `restart` starts over even for the same account, for when what its store is made from has
    /// changed, like a vault that's just been opened with a new key.
    public func use(account: String?, restart: Bool = false) {
        guard restart || account != self.account else { return }
        self.account = account
        startOver()
    }

    /// The key is about to move, and what it opened goes with it.
    public func keyChanged() {
        receiver = nil
        startOver()
    }

    private func startOver() {
        let model = MailModel(store: makeStore(account))
        model.receiver = receiver
        model.onSentToReader = onSentToReader
        current = model
    }
}
