import Foundation
import TotalityCore

/// One of the account's calendars on this device: whether it's shown, where Google's changes were last
/// read up to, and its events. A calendar that's off keeps no events.
public struct GoogleCalendarState: Codable, Equatable, Sendable, Identifiable {
    public var info: GoogleCalendarInfo
    public var isOn: Bool
    var syncToken: String?
    var events: [String: GoogleCalendarEvent]

    public var id: String { info.id }
}

/// Everything kept on this device about one connected Google account's calendars. It's sealed as one
/// blob, and the blob's name holds only an ID, so storage shows nothing about the account.
public struct GoogleCalendarAccount: Codable, Equatable, Sendable, Identifiable {
    public let address: String
    public var calendars: [GoogleCalendarState]
    public var syncedAt: Date?

    public var id: String { address }
}

/// What a sync of every connected account found.
public struct GoogleCalendarSync: Sendable, Equatable {
    public var accounts: [GoogleCalendarAccount] = []
    /// Accounts that couldn't be read this time, and why. What was kept from before still shows.
    public var problems: [String: GoogleCalendarProblem] = [:]
    /// Connected Google accounts that haven't allowed Calendar yet.
    public var needsAllowing: [String] = []
}

/// Google calendars, read only (issue 76). Google sign-in is the one shared in `TotalityCore`, so an
/// account already connected for Mail or Photos only needs one tap to allow Calendar. Events are kept
/// sealed on this device so the Calendar opens straight away and works offline. They never go to
/// Totality's server and aren't part of sync: each device reads Google itself.
public actor GoogleCalendars {
    public static let suffix = ".gcal"
    public static let sealedPurposes: [String: KeyPurpose] = [suffix: .googleCalendar]
    /// How far either side of today a calendar is read the first time. Changes after that come with
    /// Google's sync token, wherever they are.
    static let reachBack: TimeInterval = 365 * 86_400
    static let reachAhead: TimeInterval = 2 * 365 * 86_400
    /// So one huge calendar can't fill the device.
    static let mostEvents = 20_000

    private let accounts: GoogleAccounts?
    private let api: GoogleCalendarAPI?
    private let store: any BlobStore
    private let rootKey: ContentRootKey
    private let now: @Sendable () -> Date
    private var isClosed = false

    /// `accounts` is nil when this build has no Google sign-in.
    public init(accounts: GoogleAccounts?, store: any BlobStore, rootKey: ContentRootKey, now: @escaping @Sendable () -> Date = { Date() }) {
        self.accounts = accounts
        api = accounts.map { GoogleCalendarAPI(signIn: $0.signIn) }
        self.store = store
        self.rootKey = rootKey
        self.now = now
    }

    public nonisolated var isAvailable: Bool { accounts != nil }

    /// Refuses all further writes, so nothing lands under the old key during a key move.
    public func close() {
        isClosed = true
    }

    // MARK: Connecting

    /// Google's page to allow Calendar. With an account already connected for something else, it's one
    /// tap there instead of signing in again.
    public func authorization(for account: String? = nil) -> GoogleAuthorization? {
        accounts?.authorization(for: [GoogleCalendarAPI.scope], account: account)
    }

    /// Finishes on Google's page. The person can untick Calendar there, which is said, not ignored.
    public func finish(_ authorization: GoogleAuthorization, callback: URL) async throws -> String {
        guard let accounts else { throw GoogleCalendarProblem.unexpected }
        let connection: GoogleConnection
        do {
            connection = try await accounts.finish(authorization, callback: callback)
        } catch GoogleSignInError.cancelled {
            throw CancellationError()
        } catch {
            throw GoogleCalendarProblem.from(error)
        }
        guard connection.allows([GoogleCalendarAPI.scope]) else { throw GoogleCalendarProblem.notAllowed }
        return connection.address
    }

    /// What Disconnecting this account also ends, for the screen to say first.
    public func alsoEnds(_ address: String) -> Set<GoogleUse> {
        guard let connection = try? accounts?.connection(address) else { return [] }
        return GoogleUse.uses(of: connection.granted).subtracting([.calendar])
    }

    /// Takes Totality's access back at Google, which ends it for Mail and Photos on this account too,
    /// and forgets the account's calendars on this device.
    public func disconnect(_ address: String) async {
        try? await accounts?.disconnect(address)
        try? store.delete(Self.name(address))
    }

    // MARK: What's kept

    /// What's kept for every connected account, without asking Google. One that won't open is left out
    /// and fetched again on the next sync.
    public func kept() -> [GoogleCalendarAccount] {
        let connected = (try? accounts?.connections()) ?? []
        return connected.compactMap { try? load($0.address) }
    }

    /// The events to show between two moments, from the calendars that are on.
    public func events(from start: Date, to end: Date) -> [DeviceEvent] {
        Self.events(in: kept(), from: start, to: end)
    }

    static func events(in accounts: [GoogleCalendarAccount], from start: Date, to end: Date) -> [DeviceEvent] {
        var found: [DeviceEvent] = []
        for account in accounts {
            for calendar in account.calendars where calendar.isOn {
                for event in calendar.events.values where event.start < end && (event.isAllDay ? event.end.addingTimeInterval(86_400) : event.end) > start {
                    found.append(DeviceEvent(
                        id: "google-\(UUID(derivedFrom: "\(account.address)\n\(calendar.id)\n\(event.id)").uuidString.lowercased())",
                        title: event.title, location: event.location, notes: event.notes,
                        start: event.start, end: event.end, isAllDay: event.isAllDay,
                        calendarTitle: calendar.info.title, origin: .google(account: account.address, link: event.link)
                    ))
                }
            }
        }
        return found
    }

    public func setOn(_ isOn: Bool, calendar: String, account address: String) throws {
        guard !isClosed else { throw CalendarError.closed }
        guard var account = try load(address), let index = account.calendars.firstIndex(where: { $0.id == calendar }) else { return }
        account.calendars[index].isOn = isOn
        if !isOn {
            // Nothing is kept from a calendar that's off. Turning it on again reads it fresh.
            account.calendars[index].events = [:]
            account.calendars[index].syncToken = nil
        }
        try save(account)
    }

    // MARK: Syncing

    /// Reads every connected account's calendars from Google. Only changes come back after the first
    /// time, so this is quick enough to run whenever the Calendar opens or is pulled down.
    public func sync() async -> GoogleCalendarSync {
        var result = GoogleCalendarSync()
        guard let accounts, let connections = try? accounts.connections() else { return result }
        // An account disconnected elsewhere, like from Mail, leaves nothing of its calendars behind.
        let connected = Set(connections.map { Self.name($0.address) })
        for name in (try? store.names()) ?? [] where name.hasSuffix(Self.suffix) && !connected.contains(name) {
            try? store.delete(name)
        }
        for connection in connections {
            guard connection.allows([GoogleCalendarAPI.scope]) else {
                result.needsAllowing.append(connection.address)
                continue
            }
            do {
                result.accounts.append(try await sync(connection.address))
            } catch {
                result.problems[connection.address] = GoogleCalendarProblem.from(error)
                if let kept = try? load(connection.address) { result.accounts.append(kept) }
            }
        }
        return result
    }

    func sync(_ address: String) async throws -> GoogleCalendarAccount {
        guard let accounts, let api else { throw GoogleCalendarProblem.unexpected }
        guard !isClosed else { throw CalendarError.closed }
        let token = try await accounts.accessToken(address, for: [GoogleCalendarAPI.scope])
        let listed = try await api.calendars(accessToken: token)
        let before = (try? load(address)) ?? GoogleCalendarAccount(address: address, calendars: [], syncedAt: nil)
        var account = GoogleCalendarAccount(address: address, calendars: [], syncedAt: before.syncedAt)
        for info in listed {
            // A calendar seen for the first time is on, unless it's one someone else publishes, like holidays.
            var state = before.calendars.first { $0.id == info.id }
                ?? GoogleCalendarState(info: info, isOn: !info.isSubscribed, syncToken: nil, events: [:])
            state.info = info
            if state.isOn { state = try await refresh(state, api: api, accessToken: token) }
            account.calendars.append(state)
        }
        account.calendars.sort { ($0.info.isPrimary ? 0 : 1, $0.info.isSubscribed ? 1 : 0, $0.info.title) < ($1.info.isPrimary ? 0 : 1, $1.info.isSubscribed ? 1 : 0, $1.info.title) }
        account.syncedAt = now()
        guard !isClosed else { throw CalendarError.closed }
        try save(account)
        return account
    }

    /// One calendar's changes since its sync token, or all of it when there's none or Google says the
    /// token is too old.
    private func refresh(_ state: GoogleCalendarState, api: GoogleCalendarAPI, accessToken: String) async throws -> GoogleCalendarState {
        do {
            return try await read(state, api: api, accessToken: accessToken)
        } catch is GoogleSyncExpired {
            var fresh = state
            fresh.syncToken = nil
            fresh.events = [:]
            return try await read(fresh, api: api, accessToken: accessToken)
        }
    }

    private func read(_ state: GoogleCalendarState, api: GoogleCalendarAPI, accessToken: String) async throws -> GoogleCalendarState {
        var state = state
        if state.syncToken == nil { state.events = [:] }
        let current = now()
        var page: String?
        var pages = 0
        repeat {
            let answer = try await api.events(
                calendar: state.id, syncToken: state.syncToken, page: page,
                from: current.addingTimeInterval(-Self.reachBack), to: current.addingTimeInterval(Self.reachAhead), accessToken: accessToken
            )
            for id in answer.cancelled { state.events[id] = nil }
            for event in answer.changed where state.events[event.id] != nil || state.events.count < Self.mostEvents {
                state.events[event.id] = event
            }
            page = answer.nextPage
            pages += 1
            if page == nil {
                guard let next = answer.nextSync else { throw GoogleCalendarProblem.unexpected }
                state.syncToken = next
            }
        } while page != nil && pages < 50
        if page != nil { throw GoogleCalendarProblem.unexpected }
        return state
    }

    // MARK: Sealed blobs

    static func objectID(_ address: String) -> UUID {
        UUID(derivedFrom: "totality.calendar.google.\(address.lowercased())")
    }

    static func name(_ address: String) -> String {
        objectID(address).uuidString.lowercased() + suffix
    }

    private func load(_ address: String) throws -> GoogleCalendarAccount? {
        let id = Self.objectID(address)
        guard let sealed = try store.read(Self.name(address)) else { return nil }
        let account = try JSONDecoder().decode(
            GoogleCalendarAccount.self, from: ContentCipher.open(sealed, key: rootKey.objectKey(for: id, purpose: .googleCalendar), objectID: id)
        )
        guard account.address == address.lowercased() else { throw CalendarError.mismatched }
        return account
    }

    private func save(_ account: GoogleCalendarAccount) throws {
        let id = Self.objectID(account.address)
        let sealed = try ContentCipher.seal(
            JSONEncoder().encode(account), key: rootKey.objectKey(for: id, purpose: .googleCalendar), objectID: id
        )
        try store.write(sealed, as: Self.name(account.address))
    }
}
