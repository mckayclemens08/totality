import Foundation

/// A specific module item or screen context handed to Ask Totality from another module,
/// without requiring any cross-module imports.
public struct AIAskContext: Identifiable, Hashable, Sendable {
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
}
