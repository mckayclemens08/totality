import Foundation
import Observation
import TotalityCore
import WebKit

/// One file from the web. Downloads stay on this device in a folder for this account, out of the device's
/// backups. They aren't sealed, so opening one in the Reader is what puts it under the content key.
@MainActor
@Observable
public final class WebDownload: NSObject, Identifiable {
    public enum State: Equatable, Sendable {
        case running, finished, failed
    }

    public let id = UUID()
    public let file: URL
    public private(set) var state: State
    public private(set) var progress = 0.0
    /// How much has arrived, and how much there is. The total is zero when the site didn't say.
    public private(set) var received: Int64 = 0
    public private(set) var total: Int64 = 0
    /// False until the person has looked at how this one ended, so the marker stays up till then.
    var wasSeen = false
    /// Where it went in the Reader, so opening it again doesn't add a copy.
    @ObservationIgnored var inReader: ContentRef?

    @ObservationIgnored private var task: WKDownload?
    @ObservationIgnored private var watch: NSKeyValueObservation?

    public var filename: String { file.lastPathComponent }

    public var sizeText: String {
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        return total > 0 ? "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : done
    }

    /// One already on disk from an earlier launch.
    init(finished file: URL) {
        self.file = file
        state = .finished
        wasSeen = true
    }

    init(file: URL, task: WKDownload) {
        self.file = file
        self.task = task
        state = .running
        super.init()
        task.delegate = self
        // The count moves even when the site didn't give a size, and the fraction doesn't.
        watch = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let (fraction, received, total) = (progress.fractionCompleted, progress.completedUnitCount, progress.totalUnitCount)
            Task { @MainActor in
                self?.progress = fraction
                self?.received = received
                self?.total = max(0, total)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        watch = nil
    }

    private func ended(_ state: State) {
        self.state = state
        task = nil
        watch = nil
    }
}

extension WebDownload: WKDownloadDelegate {
    /// The destination is settled before this object exists, in `WebDownloadFolder`.
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        file
    }

    public func downloadDidFinish(_ download: WKDownload) {
        ended(.finished)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        ended(.failed)
    }
}

/// The account's folder of downloads.
struct WebDownloadFolder: Sendable {
    let directory: URL
    /// A site chooses the suggested name, so it's kept short and can't reach outside this folder.
    static let nameLimit = 120

    /// Keeps the file's own name and type where it can, and drops anything that could point elsewhere.
    static func safeName(_ suggested: String) -> String {
        let last = suggested.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let kept = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !":*?\"<>|".unicodeScalars.contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        guard !kept.isEmpty else { return "Download" }
        let name = kept as NSString
        let type = name.pathExtension
        let stem = name.deletingPathExtension
        guard kept.count > nameLimit else { return kept }
        guard !type.isEmpty, type.count < 12 else { return String(kept.prefix(nameLimit)) }
        return "\(stem.prefix(nameLimit - type.count - 1)).\(type)"
    }

    /// Somewhere nothing is yet, because WebKit won't overwrite a file.
    func destination(for suggested: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
        let name = Self.safeName(suggested)
        var file = directory.appendingPathComponent(name)
        var count = 1
        while FileManager.default.fileExists(atPath: file.path) {
            count += 1
            let plain = name as NSString
            let numbered = "\(plain.deletingPathExtension) \(count)"
            file = directory.appendingPathComponent(plain.pathExtension.isEmpty ? numbered : "\(numbered).\(plain.pathExtension)")
        }
        return file
    }

    func existing() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        func date(_ file: URL) -> Date {
            (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        }
        return files.sorted { date($0) > date($1) }
    }
}
