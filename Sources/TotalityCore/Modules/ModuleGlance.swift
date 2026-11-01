import Foundation

/// What a module shows on its home tile: short lines, most important first. A bigger tile shows more
/// of them. These come from private content, so they stay in memory on this device.
public struct ModuleGlance: Equatable, Sendable {
    public let lines: [String]
    /// There's nothing to show yet, so the tile says so without raising its voice.
    public let isQuiet: Bool

    public init(lines: [String], isQuiet: Bool = false) {
        self.lines = lines
        self.isQuiet = isQuiet
    }
}
