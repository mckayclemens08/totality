import Foundation

/// The public key this account first saw for each Totality name it mailed or heard from, lowercased
/// name to key. A key that's different later is never trusted on its own.
///
/// It only ever grows. A pin is never replaced or removed, here or by sync: two copies merge into
/// their union, so a delete, a rollback, or two devices pinning at once can't lose one. When two copies
/// pinned different keys for one name, the earlier pin stays, and the name is marked disputed for good,
/// so nothing from or to that name counts as proved. Disputes are kept the same way, as a union.
public struct MailPins: Codable, Equatable, Sendable {
    public struct Pin: Codable, Equatable, Sendable {
        public let key: Data
        public let pinnedAt: Date

        public init(key: Data, pinnedAt: Date) {
            self.key = key
            self.pinnedAt = pinnedAt
        }

        /// The earlier pin. A tie goes by the key's bytes, so every device settles on the same one and
        /// two devices don't hand the object back and forth forever.
        func isPreferred(over other: Pin) -> Bool {
            if pinnedAt != other.pinnedAt { return pinnedAt < other.pinnedAt }
            return key.lexicographicallyPrecedes(other.key)
        }
    }

    public private(set) var pins: [String: Pin]
    /// Names that were pinned to two different keys.
    public private(set) var disputed: Set<String>

    public init(pins: [String: Pin] = [:], disputed: Set<String> = []) {
        self.pins = pins
        self.disputed = disputed
    }

    public var isEmpty: Bool { pins.isEmpty && disputed.isEmpty }

    public func key(for name: String) -> Data? { pins[name.lowercased()]?.key }

    public func isDisputed(_ name: String) -> Bool { disputed.contains(name.lowercased()) }

    /// Adds a pin for a name that has none. A name that already has a different key keeps it, and is
    /// marked disputed.
    public mutating func add(_ name: String, key: Data, at date: Date) {
        merge(MailPins(pins: [name.lowercased(): Pin(key: key, pinnedAt: date)]))
    }

    /// The union of both. Nothing in either is ever lost.
    public mutating func merge(_ other: MailPins) {
        disputed.formUnion(other.disputed)
        for (name, theirs) in other.pins {
            guard let mine = pins[name] else {
                pins[name] = theirs
                continue
            }
            guard mine.key != theirs.key else {
                if theirs.pinnedAt < mine.pinnedAt { pins[name] = theirs }
                continue
            }
            disputed.insert(name)
            if theirs.isPreferred(over: mine) { pins[name] = theirs }
        }
    }

    public func merging(_ other: MailPins) -> MailPins {
        var merged = self
        merged.merge(other)
        return merged
    }
}
