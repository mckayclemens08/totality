import Foundation
import TotalityCore
@testable import TotalityContacts

final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    func read(_ name: String) throws -> Data? { lock.withLock { blobs[name] } }
    func write(_ data: Data, as name: String) throws { lock.withLock { blobs[name] = data } }
    func delete(_ name: String) throws { _ = lock.withLock { blobs.removeValue(forKey: name) } }
    func names() throws -> [String] { lock.withLock { Array(blobs.keys) } }
    var all: [String: Data] { lock.withLock { blobs } }
}

/// The iPhone's Contacts, as a table. Remembers what was written back.
final class FakeDevice: DeviceContacts, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: DeviceContact]
    private var state: DeviceAccess
    private var written: [DeviceContact] = []
    let grants: DeviceAccess

    init(_ contacts: [DeviceContact], access: DeviceAccess = .full, grants: DeviceAccess = .full) {
        stored = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        state = access
        self.grants = grants
    }

    var access: DeviceAccess { lock.withLock { state } }
    var writes: [DeviceContact] { lock.withLock { written } }

    func change(_ contact: DeviceContact) { lock.withLock { stored[contact.id] = contact } }

    func requestAccess() async -> DeviceAccess {
        lock.withLock {
            state = grants
            return state
        }
    }

    func all() async throws -> [DeviceContact] {
        try lock.withLock {
            guard state == .full || state == .limited else { throw CocoaError(.userCancelled) }
            return stored.values.sorted { $0.id < $1.id }
        }
    }

    func contacts(_ ids: [String]) async throws -> [DeviceContact] {
        lock.withLock { ids.compactMap { stored[$0] } }
    }

    func update(_ contact: DeviceContact) async throws {
        lock.withLock {
            written.append(contact)
            var kept = contact
            kept.photo = stored[contact.id]?.photo
            stored[contact.id] = kept
        }
    }
}

let friday = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18, a Wednesday in UTC

var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

func sam(at date: Date = friday) -> ContactCard {
    ContactCard(
        givenName: "Sam", familyName: "Okafor", phones: [.init(label: "Mobile", value: "(801) 555-0142")],
        emails: [.init(label: "Email", value: "sam.okafor@gmail.com")], birthday: .init(month: 3, day: 14),
        notes: "Climbing partner. Has the 70 m rope.", labels: ["Climbing"], username: "samokafor", createdAt: date
    )
}

func priya(at date: Date = friday) -> ContactCard {
    ContactCard(
        givenName: "Priya", familyName: "Patel", phones: [.init(label: "Mobile", value: "(801) 555-0199")],
        birthday: .init(month: 11, day: 22, year: 1999), createdAt: date
    )
}

let momOnPhone = DeviceContact(
    id: "device-mom", givenName: "Linda", familyName: "Clemens", nickname: "Mom",
    phones: [.init(label: "Mobile", value: "(801) 555-0110")],
    emails: [.init(label: "Home", value: "linda@example.com"), .init(label: "Work", value: "linda@work.example.com")]
)

let elenaOnPhone = DeviceContact(
    id: "device-elena", givenName: "Elena", familyName: "Alvarez", company: "Philosophy · JFSB 4010",
    emails: [.init(label: "Work", value: "elena_alvarez@byu.edu")]
)

@MainActor
func makeModel(_ store: MemoryBlobStore = MemoryBlobStore(), key: ContentRootKey? = nil, device: FakeDevice? = nil) throws -> (ContactsModel, ContactVault) {
    let vault = ContactVault(store: store, rootKey: try key ?? ContentRootKey.generate())
    let defaults = UserDefaults(suiteName: "contacts-tests-\(UUID().uuidString)")!
    let model = ContactsModel(vault: vault, device: device, defaults: defaults, calendar: utc, now: { friday })
    return (model, vault)
}
