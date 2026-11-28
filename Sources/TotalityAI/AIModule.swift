import Foundation
import TotalityCore

/// Ask Totality's entry in the shared registry (`ModuleID.ai`).
/// It only reads module data that the user explicitly grants and never imports any sibling module.
public struct AIModule: ContentHandler {
    public let module = ModuleID.ai
    public let kinds: Set<ContentKind> = []

    public init() {}
}
