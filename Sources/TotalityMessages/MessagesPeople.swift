import Foundation
import Observation
import TotalityCore
import TotalityUI

/// The public profiles of the people in your chats: name, bio and a photo rebuilt on this device. Each is
/// kept for a day, on this device only, and fetched again on pull-to-refresh. Everything here is public,
/// so the file isn't sealed, but it lives in the account's own cache folder and goes when that does.
@MainActor
@Observable
public final class MessagesPeople {
    public static let freshFor: TimeInterval = 24 * 60 * 60

    struct Entry: Codable, Equatable {
        /// Nil when they have no profile this account can see.
        let profile: PublicProfile?
        let fetched: Date
    }

    /// Set by the app from the `ModuleRegistry`. Without it, everyone shows as their handle.
    public var directory: (any ProfileDirectory)?
    private(set) var entries: [String: Entry] = [:]
    /// Handles whose last fetch failed with nothing saved from before.
    private(set) var failed: Set<String> = []
    private var fetching: Set<String> = []
    private var file: URL?
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The handle in a Matrix ID, for people on Totality's own server only. Nobody else has a profile here.
    public nonisolated static func handle(of matrixID: String) -> String? {
        guard let name = MessagesUsername.normalized(MessagesUsername.display(matrixID)),
              matrixID == "@\(name):\(MailDomain.name)" else { return nil }
        return name
    }

    // MARK: Reading

    public func profile(ofMatrixID matrixID: String) -> PublicProfile? {
        Self.handle(of: matrixID).flatMap { entries[$0]?.profile }
    }

    /// What to call someone: their profile's name once it's known, else their handle.
    public func name(ofMatrixID matrixID: String) -> String {
        profile(ofMatrixID: matrixID)?.name ?? MessagesUsername.display(matrixID)
    }

    public func phase(of username: String) -> PersonProfileView.Phase {
        if let entry = entries[username] { return entry.profile.map(PersonProfileView.Phase.found) ?? .missing }
        if failed.contains(username) { return .failed("Their profile didn't load. You may be offline.") }
        return .loading
    }

    // MARK: Fetching

    /// Fetches anyone not known yet or last fetched more than a day ago.
    public func want(matrixIDs: [String]) async {
        let handles = Set(matrixIDs.compactMap(Self.handle(of:)))
        let stale = handles.filter { entries[$0].map { now().timeIntervalSince($0.fetched) >= Self.freshFor } ?? true }
        await fetch(stale)
    }

    /// Fetches everyone again, for pull-to-refresh.
    public func refresh() async {
        await fetch(Set(entries.keys).union(failed))
    }

    /// Fetches one person again, such as from their profile's Try again.
    public func reload(_ username: String) async {
        await fetch([username])
    }

    private func fetch(_ handles: Set<String>) async {
        guard let directory else { return }
        let todo = handles.subtracting(fetching)
        guard !todo.isEmpty else { return }
        fetching.formUnion(todo)
        defer { fetching.subtract(todo) }
        let file = self.file
        await withTaskGroup(of: (String, Result<PublicProfile?, Error>).self) { group in
            for handle in todo {
                group.addTask {
                    do { return (handle, .success(try await directory.profile(of: handle))) } catch { return (handle, .failure(error)) }
                }
            }
            for await (handle, result) in group {
                // A sign-out or account change while this was out drops what came back.
                guard self.file == file else { continue }
                switch result {
                case .success(let profile):
                    entries[handle] = Entry(profile: profile, fetched: now())
                    failed.remove(handle)
                case .failure:
                    // Offline keeps whatever was saved before, however old.
                    if entries[handle] == nil { failed.insert(handle) }
                }
            }
        }
        save()
    }

    // MARK: The file

    /// Opens the saved profiles for an account. The folder is the account's own Messages cache.
    func open(file: URL?) {
        self.file = file
        entries = [:]
        failed = []
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        // Only well-formed handles come back, and a saved photo is checked again before it's used.
        for (handle, entry) in saved {
            guard MessagesUsername.normalized(handle) == handle, entry.profile.map({ $0.username == handle }) ?? true else { continue }
            let photo = entry.profile?.photo.flatMap(SafeAvatar.prepare)
            entries[handle] = Entry(
                profile: entry.profile.map { PublicProfile(username: $0.username, displayName: $0.displayName, bio: $0.bio, photo: photo) },
                fetched: entry.fetched
            )
        }
    }

    /// Forgets everyone, for a sign-out. The file stays for that account's next sign-in.
    func close() {
        file = nil
        entries = [:]
        failed = []
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
