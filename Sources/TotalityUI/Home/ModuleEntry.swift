import TotalityCore

/// How a module appears on the home screen.
public struct ModuleEntry: Identifiable, Sendable, Equatable {
    public let id: ModuleID
    public let name: String
    public let systemImage: String

    public init(id: ModuleID, name: String, systemImage: String) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
    }

    // SF Symbols stand in until the owner decides SF Symbols vs Lucide (proposal §11-E). This
    // order is also a placeholder: the centre bubble and default arrangement are still open.
    public static let all: [ModuleEntry] = [
        .init(id: .messages, name: "Messages", systemImage: "bubble.left"),
        .init(id: .reader, name: "Reader", systemImage: "book"),
        .init(id: .calendar, name: "Calendar", systemImage: "calendar"),
        .init(id: .ai, name: "Assistant", systemImage: "sparkles"),
        .init(id: .player, name: "Music", systemImage: "music.note"),
        .init(id: .mail, name: "Mail", systemImage: "envelope"),
        .init(id: .photos, name: "Photos", systemImage: "photo.on.rectangle"),
        .init(id: .money, name: "Money", systemImage: "dollarsign.circle"),
        .init(id: .calls, name: "Calls", systemImage: "phone"),
        .init(id: .social, name: "Social", systemImage: "square.grid.2x2"),
    ]
}
