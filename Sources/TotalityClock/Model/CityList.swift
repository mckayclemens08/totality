import Foundation

/// The cities someone can add, from the time zones the device already knows. Nothing is looked up on the
/// network, so what's searched for never leaves the iPhone.
public enum CityList {
    public struct Choice: Hashable, Identifiable, Sendable {
        public let name: String
        /// The region, like "America" or "Europe".
        public let region: String
        public let timeZoneID: String

        public var id: String { timeZoneID }
    }

    /// Every named city, A to Z. Zones that aren't a place, like "GMT" or "Etc/GMT+5", are left out.
    public static let all: [Choice] = TimeZone.knownTimeZoneIdentifiers.compactMap(choice(for:))
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func choice(for identifier: String) -> Choice? {
        let parts = identifier.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] != "Etc" else { return nil }
        return Choice(name: parts.last!.replacingOccurrences(of: "_", with: " "), region: parts[0].replacingOccurrences(of: "_", with: " "), timeZoneID: identifier)
    }

    /// Cities whose name or region starts a word with what was typed.
    public static func search(_ text: String) -> [Choice] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { choice in
            [choice.name, choice.region].contains { field in
                field.split(separator: " ").contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
                    || field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }
    }
}
