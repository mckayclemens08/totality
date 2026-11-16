import Foundation
import Testing

/// The owner doesn't want a sunken look anywhere ("I just don't like the sunken-in look", "anywhere",
/// 2026-11-15, issue 132). This reads every Swift source file and fails on a pressed-in surface.
@Suite struct NoSunkenLookTests {
    private static let banned = ["neumorphic(.pressed", "? .pressed :", "elevationPressed", ".shadow(.inner("]

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("No source file draws a pressed-in or inset surface")
    func noSunkenLook() throws {
        var found: [String] = []
        var scanned = 0
        for folder in ["Sources", "App"] {
            guard let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    for pattern in Self.banned where code.contains(pattern) {
                        found.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(number + 1): \(pattern)")
                    }
                }
            }
        }
        #expect(scanned > 100, "The scan found too few files, so it isn't looking in the right place.")
        #expect(found.isEmpty, "Sunken look found:\n\(found.joined(separator: "\n"))")
    }
}
