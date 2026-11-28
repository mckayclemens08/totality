import Foundation
import TotalityCore

/// Bridge supplied by the app so `TotalityAI` reads only explicitly granted module data
/// and executes approved proposals without importing any sibling module.
@MainActor
public protocol AISourceBridge: AnyObject {
    func fetchItems(for module: ModuleID, limit: Int) async throws -> [AIContextItem]
    func execute(_ action: AIProposedAction, editedBody: String?) async throws -> String
}

public enum AISourceBridgeError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        }
    }
}
