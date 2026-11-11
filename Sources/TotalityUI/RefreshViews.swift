import SwiftUI
import TotalityCore

public extension View {
    /// Pulling down anywhere inside refreshes, and the system spinner stays until every step is done.
    /// Automatic refreshes come from `AppRefresh`, so they need nothing here.
    func pullsToRefresh(with refresher: Refresher) -> some View {
        refreshable { await refresher.refresh(.pulled) }
    }
}

/// One small line, only when something went wrong after a pull or kept going wrong. Never "Updating",
/// and never a full-screen wait.
public struct RefreshStatusLine: View {
    private let refresher: Refresher

    public init(_ refresher: Refresher) {
        self.refresher = refresher
    }

    public var body: some View {
        if let problem = refresher.problem {
            let theme = Theme.current
            let offline = problem == Refresher.offlineLine
            Label(problem, systemImage: offline ? "wifi.slash" : "exclamationmark.arrow.triangle.2.circlepath")
                .font(Typeface.caption)
                .foregroundStyle(offline ? theme.textSecondary.color : theme.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
        }
    }
}
