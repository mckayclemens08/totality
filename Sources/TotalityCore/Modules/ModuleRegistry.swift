import Foundation

/// A module's entry in the registry. Modules never import each other; this is how they meet.
public protocol ContentHandler: Sendable {
    var module: ModuleID { get }
    var kinds: Set<ContentKind> { get }
}

/// A module whose content other modules can attach. Refs are the only thing that crosses over.
public protocol ContentProvider: ContentHandler {
    func attachable() async throws -> [ContentRef]
    /// The ref as it is now, or nil if the content is gone.
    func current(_ ref: ContentRef) async throws -> ContentRef?
}

/// A module that takes content another module hands it. The sender only gets a ref back, and `current`
/// tells it whether that content is still there.
public protocol ContentReceiver: ContentProvider {
    func receive(noteTitled title: String, body: String) async throws -> ContentRef
    func receive(file data: Data, named filename: String) async throws -> ContentRef
}

public enum ModuleRegistryError: Error, Equatable {
    case duplicateModule(ModuleID)
    case duplicateKind(ContentKind)
}

/// Resolves a `ContentRef` to the module that handles it. Built once at launch and never changed.
public struct ModuleRegistry: Sendable {
    private let byKind: [ContentKind: any ContentHandler]
    private let handlers: [any ContentHandler]

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
        self.handlers = handlers
    }

    /// Nil means nothing installed can open this, so callers show the preview chip alone.
    public func handler(for ref: ContentRef) -> (any ContentHandler)? {
        byKind[ref.kind]
    }

    /// What a module can attach, which is everything except its own content.
    public func providers(for module: ModuleID) -> [any ContentProvider] {
        handlers.compactMap { $0 as? any ContentProvider }.filter { $0.module != module }
    }

    /// The module that keeps what `module` hands over, which is never `module` itself.
    public func receiver(for module: ModuleID) -> (any ContentReceiver)? {
        handlers.compactMap { $0 as? any ContentReceiver }.first { $0.module != module }
    }

    /// Every module that can be searched, in the order they were registered.
    public var searchers: [any ModuleSearcher] {
        handlers.compactMap { $0 as? any ModuleSearcher }
    }
}
