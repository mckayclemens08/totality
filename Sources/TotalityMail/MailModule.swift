import TotalityCore

/// Mail's entry in the registry. It takes nothing from other modules yet, and search inside Totality
/// doesn't reach it. Saving an attachment goes the other way, to whichever module receives files.
public struct MailModule: ContentHandler {
    public let module = ModuleID.mail
    public let kinds: Set<ContentKind> = []

    public init() {}
}
