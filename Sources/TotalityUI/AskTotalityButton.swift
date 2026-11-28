import SwiftUI
import TotalityCore

/// App-provided action that opens Ask Totality from any module, optionally focused on one item.
@MainActor
public struct AskTotalityAction: Sendable {
    private let open: @MainActor @Sendable (AIAskContext?) -> Void

    public init(_ open: @escaping @MainActor @Sendable (AIAskContext?) -> Void) {
        self.open = open
    }

    public func callAsFunction(_ context: AIAskContext? = nil) {
        open(context)
    }
}

private struct AskTotalityKey: EnvironmentKey {
    static let defaultValue: AskTotalityAction? = nil
}

extension EnvironmentValues {
    public var askTotality: AskTotalityAction? {
        get { self[AskTotalityKey.self] }
        set { self[AskTotalityKey.self] = newValue }
    }
}

/// Circular raised sparkles button placed in module headers (like an in-module AI quick trigger).
public struct AskTotalityButton: View {
    @Environment(\.askTotality) private var askTotality
    private let context: AIAskContext?

    public init(context: AIAskContext? = nil) {
        self.context = context
    }

    public var body: some View {
        if let askTotality {
            HeaderButton("Ask Totality", systemImage: "sparkles") {
                askTotality(context)
            }
        }
    }
}

/// Menu action placed beside "Add to Tasks" inside item menus and context menus.
public struct AskTotalityMenuButton: View {
    @Environment(\.askTotality) private var askTotality
    private let context: AIAskContext

    public init(context: AIAskContext) {
        self.context = context
    }

    public var body: some View {
        if let askTotality {
            Button("Ask Totality", systemImage: "sparkles") {
                askTotality(context)
            }
        }
    }
}
