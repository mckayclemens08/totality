import TotalityCore

/// The Reader's entry in the registry. `doc` waits for rich documents (proposal §11-M).
public struct ReaderModule: ContentHandler {
    public let module = ModuleID.reader
    public let kinds: Set<ContentKind> = [.note, .file]

    public init() {}
}
