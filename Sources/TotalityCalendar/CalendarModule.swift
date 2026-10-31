import TotalityCore

/// The Calendar's entry in the registry. Other modules can't attach events yet.
public struct CalendarModule: ContentHandler {
    public let module = ModuleID.calendar
    public let kinds: Set<ContentKind> = [.event]

    public init() {}
}
