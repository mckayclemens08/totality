import Foundation
import TotalityCore

public enum AIScope: String, Codable, Sendable {
    case read, propose
}

/// Per-module access rule. Every module starts with `read = false` and `propose = false`.
public struct AIAccessGrant: Codable, Sendable, Equatable, Identifiable {
    public let module: ModuleID
    public let name: String
    public let supportsPropose: Bool
    public var read: Bool
    public var propose: Bool
    public var lastUsed: Date?

    public var id: ModuleID { module }

    public init(
        module: ModuleID,
        name: String,
        supportsPropose: Bool = true,
        read: Bool = false,
        propose: Bool = false,
        lastUsed: Date? = nil
    ) {
        self.module = module
        self.name = name
        self.supportsPropose = supportsPropose
        self.read = read
        self.propose = supportsPropose ? propose : false
        self.lastUsed = lastUsed
    }

    public var isAnyGranted: Bool { read || propose }

    public static let defaultOrder: [(module: ModuleID, name: String, supportsPropose: Bool)] = [
        (.calendar, "Calendar", true),
        (.mail, "Mail", true),
        (.tasks, "Tasks", true),
        (.reader, "Reader", true),
        (.weather, "Weather", false),
        (.messages, "Messages", true),
        (.contacts, "Contacts", true),
        (.hiking, "Hiking", true),
        (.player, "Music", false),
    ]

    public static var emptyGrants: [ModuleID: AIAccessGrant] {
        var map: [ModuleID: AIAccessGrant] = [:]
        for entry in defaultOrder {
            map[entry.module] = AIAccessGrant(module: entry.module, name: entry.name, supportsPropose: entry.supportsPropose)
        }
        return map
    }
}

/// Decrypted on-device item returned by a granted module bridge. Never leaves the iPhone.
public struct AIContextItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let module: ModuleID
    public let title: String
    public let detail: String
    public let body: String
    public let date: Date?
    public let metadata: [String: String]

    public init(
        id: String,
        module: ModuleID,
        title: String,
        detail: String = "",
        body: String = "",
        date: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.module = module
        self.title = title
        self.detail = detail
        self.body = body
        self.date = date
        self.metadata = metadata
    }

    public init(_ context: AIAskContext) {
        self.init(
            id: context.id,
            module: context.module,
            title: context.title,
            detail: context.detail,
            body: context.body,
            date: context.date,
            metadata: context.metadata
        )
    }
}

/// Summary chip shown under a turn to make every tool read visible.
public struct AIToolUsage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let module: ModuleID
    public let count: Int
    public let label: String

    public init(id: UUID = UUID(), module: ModuleID, count: Int, label: String) {
        self.id = id
        self.module = module
        self.count = count
        self.label = label
    }
}

public enum AIProposedActionKind: String, Codable, Sendable {
    case replyEmail
    case createTask
    case createCalendarEvent
    case saveReaderNote

    /// Outward-facing sends/posts/deletes always carry explicit warning labels.
    public var requiresExplicitSendWarning: Bool {
        self == .replyEmail
    }
}

/// A draft action proposed by Ask Totality. Nothing runs without an explicit tap on Approve.
public struct AIProposedAction: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, approved, declined
    }

    public let id: UUID
    public let kind: AIProposedActionKind
    public let module: ModuleID
    public let title: String
    public let recipientOrTarget: String?
    public let subtitle: String?
    public var body: String
    public var metadata: [String: String]
    public var status: Status

    public init(
        id: UUID = UUID(),
        kind: AIProposedActionKind,
        module: ModuleID,
        title: String,
        recipientOrTarget: String? = nil,
        subtitle: String? = nil,
        body: String,
        metadata: [String: String] = [:],
        status: Status = .pending
    ) {
        self.id = id
        self.kind = kind
        self.module = module
        self.title = title
        self.recipientOrTarget = recipientOrTarget
        self.subtitle = subtitle
        self.body = body
        self.metadata = metadata
        self.status = status
    }
}

/// One turn in the Ask Totality sheet.
public struct AIMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let date: Date
    public let aboutLabel: String?
    public let sourcesRead: [AIToolUsage]
    public var proposal: AIProposedAction?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        date: Date = Date(),
        aboutLabel: String? = nil,
        sourcesRead: [AIToolUsage] = [],
        proposal: AIProposedAction? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.aboutLabel = aboutLabel
        self.sourcesRead = sourcesRead
        self.proposal = proposal
    }
}

/// Sealed audit record written every time Ask Totality reads a module, proposes an action, or changes a grant.
public struct AIActivityEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case read = "Read"
        case proposed = "Proposed"
        case grant = "Grant"
    }

    public enum Outcome: String, Codable, Sendable {
        case ok, declined, info
    }

    public let id: UUID
    public let date: Date
    public let moduleName: String
    public let module: ModuleID?
    public let kind: Kind
    public let what: String
    public var result: String?
    public var outcome: Outcome

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        moduleName: String,
        module: ModuleID? = nil,
        kind: Kind,
        what: String,
        result: String? = nil,
        outcome: Outcome = .info
    ) {
        self.id = id
        self.date = date
        self.moduleName = moduleName
        self.module = module
        self.kind = kind
        self.what = what
        self.result = result
        self.outcome = outcome
    }
}

/// Local 3-4B 4-bit open model status. Works offline and without Apple Intelligence.
public enum LocalModelStatus: Equatable, Sendable {
    case ready(modelName: String, sizeLabel: String)
    case notDownloaded(modelName: String, sizeLabel: String)
    case downloading(progress: Double)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
