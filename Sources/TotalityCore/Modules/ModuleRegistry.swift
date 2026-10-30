/// A module's entry in the registry. Modules never import each other; this is how they meet.
public protocol ContentHandler: Sendable {
    var module: ModuleID { get }
    var kinds: Set<ContentKind> { get }
}

public enum ModuleRegistryError: Error, Equatable {
    case duplicateModule(ModuleID)
    case duplicateKind(ContentKind)
}

/// Resolves a `ContentRef` to the module that handles it. Built once at launch and never changed.
public struct ModuleRegistry: Sendable {
    private let byKind: [ContentKind: any ContentHandler]

    public init(handlers: [any ContentHandler]) throws {
        var modules = Set<ModuleID>()
        var byKind: [ContentKind: any ContentHandler] = [:]
        for handler in handlers {
            guard modules.insert(handler.module).inserted else {
                throw ModuleRegistryError.duplicateModule(handler.module)
            }
            for kind in handler.kinds {
                guard byKind[kind] == nil else { throw ModuleRegistryError.duplicateKind(kind) }
                byKind[kind] = handler
            }
        }
        self.byKind = byKind
    }

    /// Nil means nothing installed can open this, so callers show the preview chip alone.
    public func handler(for ref: ContentRef) -> (any ContentHandler)? {
        byKind[ref.kind]
    }
}
