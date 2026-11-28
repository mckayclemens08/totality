import SwiftUI
import TotalityCore
import TotalityUI

/// AI activity log (issue 252): every module read, proposal outcome, and grant change, sealed on device.
public struct AIActivityView: View {
    public enum Filter: String, CaseIterable, Hashable {
        case all = "All"
        case read = "Read"
        case proposed = "Proposed"
        case grants = "Grants"
    }

    @Bindable private var model: AIModel
    private let onDone: () -> Void
    @State private var filter = Filter.all

    public init(model: AIModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    private var filtered: [AIActivityEntry] {
        model.activity.filter { entry in
            switch filter {
            case .all: true
            case .read: entry.kind == .read
            case .proposed: entry.kind == .proposed
            case .grants: entry.kind == .grant
            }
        }
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Everything Ask Totality read and did.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)

                    FilterPills(Filter.allCases, selection: $filter) { $0.rawValue }

                    if filtered.isEmpty {
                        Text("No activity yet.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                            .itemCard()
                    } else {
                        VStack(spacing: Space.s3) {
                            ForEach(filtered) { entry in
                                activityRow(entry, theme: theme)
                            }
                        }
                    }

                    Text("Kept sealed on your devices. The server can't read it.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)

                    Button("Clear older than 30 days") {
                        Task { await model.clearActivityOlderThan30Days() }
                    }
                    .font(Typeface.callout)
                    .foregroundStyle(theme.accent.color)
                    .disabled(model.activity.isEmpty)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .tint(theme.accent.color)
    }

    private func activityRow(_ entry: AIActivityEntry, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack {
                Text("\(entry.moduleName) · \(entry.kind.rawValue)")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Text(entry.what)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let result = entry.result, !result.isEmpty {
                Text(result)
                    .font(Typeface.caption.weight(.medium))
                    .foregroundStyle(outcomeColor(entry.outcome, theme: theme))
            }
        }
        .itemCard()
    }

    private func outcomeColor(_ outcome: AIActivityEntry.Outcome, theme: Theme) -> Color {
        switch outcome {
        case .ok: theme.success.color
        case .declined: theme.textSecondary.color
        case .info: theme.accent.color
        }
    }
}
