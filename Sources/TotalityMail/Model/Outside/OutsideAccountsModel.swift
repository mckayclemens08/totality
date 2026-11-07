import Foundation
import Observation

/// The outside accounts screen's state. Nothing is shown as added until the provider accepted the
/// sign-in and it was kept, and a change that fails says why and leaves things as they were.
@MainActor
@Observable
public final class OutsideAccountsModel {
    public enum Phase: Equatable { case loading, ready, failed }

    public private(set) var phase = Phase.loading
    public private(set) var accounts: [OutsideAccount] = []
    /// Accounts with a change on its way, so their controls wait.
    public private(set) var busy = Set<UUID>()
    public private(set) var isAdding = false
    /// What went wrong with the last change to an account already here.
    public var notice: String?

    @ObservationIgnored private let store: any OutsideAccountStore

    public init(store: any OutsideAccountStore) {
        self.store = store
    }

    public var canAddMore: Bool { accounts.count < OutsideAccountLimits.most }

    public func load() async {
        do {
            accounts = try await store.outsideAccounts()
            phase = .ready
        } catch {
            phase = accounts.isEmpty ? .failed : .ready
        }
    }

    /// Nil when it was added. Otherwise what to tell the person, and nothing was kept.
    public func add(_ provider: OutsideProvider, address: String, appPassword: String) async -> String? {
        guard let signIn = OutsideSignIn(provider: provider, address: address, appPassword: appPassword) else {
            return "Enter the full address and the app password."
        }
        guard !isAdding else { return "Still checking the last one." }
        isAdding = true
        defer { isAdding = false }
        do {
            _ = try await store.addOutside(signIn)
            await load()
            return nil
        } catch let error as OutsideAccountError {
            return OutsideWording.problem(error, provider: provider)
        } catch {
            return OutsideWording.problem(.unavailable, provider: provider)
        }
    }

    public func remove(_ account: OutsideAccount) async {
        await change(account) { try await self.store.removeOutside(account.id) }
    }

    public func setSending(_ account: OutsideAccount, on: Bool) async {
        await change(account) { try await self.store.setOutsideSending(account.id, on: on) }
    }

    private func change(_ account: OutsideAccount, _ work: @escaping () async throws -> Void) async {
        guard !busy.contains(account.id) else { return }
        busy.insert(account.id)
        defer { busy.remove(account.id) }
        do {
            try await work()
            notice = nil
        } catch let error as OutsideAccountError {
            notice = OutsideWording.problem(error, provider: account.provider)
        } catch {
            notice = OutsideWording.problem(.unavailable, provider: account.provider)
        }
        await load()
    }
}
