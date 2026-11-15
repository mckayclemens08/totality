import Foundation

/// One earlier version of a doc, as its list shows it. The text is sealed separately, under the version's
/// own ID, and both stay on the device where the version was made.
public struct DocVersion: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let savedAt: Date
    public let title: String
    public let words: Int
    public let byteCount: Int
}

/// Which versions a doc keeps. Every recent one stays. Further back, one an hour for a day, one a day
/// for a month, and one a week after that, up to a limit, so a long project keeps its history without
/// the device filling up.
enum DocVersions {
    static let mostKept = 100
    static let allRecent = 20

    /// Newest first.
    static func thinned(_ versions: [DocVersion], now: Date) -> [DocVersion] {
        let newest = versions.sorted { $0.savedAt > $1.savedAt }
        var kept: [DocVersion] = []
        var buckets = Set<String>()
        for (index, version) in newest.enumerated() {
            if index < allRecent {
                kept.append(version)
                continue
            }
            let age = now.timeIntervalSince(version.savedAt)
            let seconds = version.savedAt.timeIntervalSince1970
            let bucket = switch age {
            case ..<(24 * 3600): "h\(Int(floor(seconds / 3600)))"
            case ..<(30 * 24 * 3600): "d\(Int(floor(seconds / 86400)))"
            default: "w\(Int(floor(seconds / (7 * 86400))))"
            }
            if buckets.insert(bucket).inserted { kept.append(version) }
        }
        return Array(kept.prefix(mostKept))
    }

    static func words(_ markdown: String) -> Int {
        MarkdownText.plainText(markdown).split(whereSeparator: { $0.isWhitespace }).count
    }
}
