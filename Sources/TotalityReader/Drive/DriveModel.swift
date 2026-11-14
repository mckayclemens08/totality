import AuthenticationServices
import Foundation
import Observation
import TotalityCore

/// What the Reader's Google Drive screens show. All the work happens in `GoogleDrive`.
@MainActor
@Observable
public final class DriveModel {
    /// Shows Google's page and hands back where it returned to. The view supplies it, because only a view
    /// can present Google's sign-in sheet.
    public typealias SignIn = @MainActor (_ page: URL, _ callbackScheme: String) async throws -> URL

    /// The honest label for anything from Drive (rule 5): Google holds it, and can read it.
    public nonisolated static let label = "Stored in Google Drive, not end-to-end encrypted"
    public nonisolated static let explanation =
        "Linked folders stay in Google Drive. Google can read them, so they aren't end-to-end encrypted. "
        + "Totality asks Google for your whole Drive but shows only the folders you link. This device talks to Google "
        + "directly, and Totality's server never sees your files, their names, or your Google sign-in."

    public private(set) var accounts: [DriveAccount] = []
    public private(set) var links: [DriveLink] = []
    /// True while Google's page is open or its answer is being checked.
    public private(set) var isConnecting = false
    /// A problem to show on the Drive screens, cleared when it's dismissed or the next try starts.
    public var problem: String?

    let drive: GoogleDrive

    public init(drive: GoogleDrive) {
        self.drive = drive
    }

    public var isAvailable: Bool { drive.isAvailable }

    public func load() async {
        accounts = await drive.connections()
        do {
            links = try await drive.links()
        } catch {
            problem = "Your linked Drive folders couldn't be read on this device."
        }
    }

    public func links(for account: String) -> [DriveLink] {
        links.filter { $0.account == account }
    }

    public func isLinked(_ folder: DriveEntry, account: String) -> Bool {
        links.contains { $0.account == account && $0.folderID == folder.id }
    }

    // MARK: Connecting

    /// Allows Drive on an account, or connects a new one when `account` is nil. Returns the account
    /// that now allows Drive, or nil if it didn't happen. An account that already allows it needs nothing.
    public func connect(_ account: String?, signIn: SignIn) async -> String? {
        if let account, accounts.first(where: { $0.address == account })?.allowsDrive == true { return account }
        guard let authorization = await drive.authorization(for: account) else {
            problem = DriveProblem.notSetUp.message
            return nil
        }
        isConnecting = true
        problem = nil
        defer { isConnecting = false }
        do {
            let callback = try await signIn(authorization.url, authorization.callbackScheme)
            let address = try await drive.finish(authorization, callback: callback)
            await load()
            return address
        } catch is CancellationError {
            return nil
        } catch let error as DriveProblem {
            problem = error == .notAllowed
                ? "Drive wasn't allowed on Google's page, so Totality can't see its folders. Try again and leave Drive ticked."
                : error.message
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The person closed Google's page, which isn't a problem to show.
            return nil
        } catch {
            problem = DriveProblem.from(error).message
        }
        await load()
        return nil
    }

    // MARK: Choosing

    public func folders(in place: DrivePlace, account: String) async throws -> [DriveEntry] {
        try await drive.folders(in: place, account: account)
    }

    /// Links or unlinks a folder the chooser shows.
    public func setLinked(_ isLinked: Bool, folder: DriveEntry, account: String) async {
        do {
            if isLinked {
                try await drive.link(folder, account: account)
            } else if let link = links.first(where: { $0.account == account && $0.folderID == folder.id }) {
                try await drive.unlink(link)
            }
        } catch {
            problem = isLinked ? "\(folder.name) couldn't be linked." : "\(folder.name) couldn't be unlinked."
        }
        await load()
    }

    public func unlink(_ link: DriveLink) async {
        do {
            try await drive.unlink(link)
        } catch {
            problem = "\(link.name) couldn't be unlinked."
        }
        await load()
    }

    /// For a key move or a change of account.
    public func close() async {
        await drive.close()
        links = []
        accounts = []
    }
}
