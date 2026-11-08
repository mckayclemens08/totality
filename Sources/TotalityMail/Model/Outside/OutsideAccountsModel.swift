import AuthenticationServices
import Foundation
import Observation

/// Opens a provider's own sign-in page and hands back the address it returned to. The screen supplies
/// this, from SwiftUI's web authentication session.
public typealias OutsideWebSignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

/// How adding an account ended.
public enum OutsideAddOutcome: Equatable, Sendable {
    case added
    /// The person closed the sign-in page, so nothing needs saying.
    case cancelled
    case failed(String)
}

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

    /// Signs in on Google's own page, asking only to read, then keeps the account.
    public func addGoogle(signingIn web: OutsideWebSignIn) async -> OutsideAddOutcome {
        guard !isAdding else { return .failed("Still checking the last one.") }
        isAdding = true
        defer { isAdding = false }
        do {
            let request = try await store.googleSignIn(sendingFor: nil)
            let callback = try await web(request.url, request.callbackScheme)
            _ = try await store.addGoogle(request, callback: callback)
            await load()
            return .added
        } catch {
            guard let error = Self.accountError(error) else { return .cancelled }
            return .failed(OutsideWording.problem(error, provider: .gmail))
        }
    }

    public func remove(_ account: OutsideAccount) async {
        await change(account) { try await self.store.removeOutside(account.id) }
    }

    /// Turning a Gmail account's sending on asks Google first, on its own page.
    public func setSending(_ account: OutsideAccount, on: Bool, signingIn web: @escaping OutsideWebSignIn) async {
        guard on, account.provider.signsInWithGoogle else {
            await change(account) { try await self.store.setOutsideSending(account.id, on: on) }
            return
        }
        await change(account) {
            let request = try await self.store.googleSignIn(sendingFor: account.id)
            let callback = try await web(request.url, request.callbackScheme)
            try await self.store.allowGoogleSending(account.id, request, callback: callback)
        }
    }

    /// Nil for a closed sign-in page, which isn't a problem to show.
    static func accountError(_ error: any Error) -> OutsideAccountError? {
        if let error = error as? OutsideAccountError { return error == .cancelled ? nil : error }
        if let error = error as? ASWebAuthenticationSessionError {
            return error.code == .canceledLogin ? nil : .problem(.unexpected)
        }
        if error is CancellationError { return nil }
        return .unavailable
    }

    private func change(_ account: OutsideAccount, _ work: @escaping () async throws -> Void) async {
        guard !busy.contains(account.id) else { return }
        busy.insert(account.id)
        defer { busy.remove(account.id) }
        do {
            try await work()
            notice = nil
        } catch {
            notice = Self.accountError(error).map { OutsideWording.problem($0, provider: account.provider) }
        }
        await load()
    }
}
