import SwiftUI
import TotalityCore
import TotalityUI

/// AI access grants (issue 252): everything starts off; Read and Propose can be turned on or off per module.
public struct AIAccessView: View {
    @Bindable private var model: AIModel
    private let onDone: () -> Void

    public init(model: AIModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Ask Totality starts with access to nothing. Turn on only what you want it to use. You can turn anything off at any time.")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Module")
                                .font(Typeface.caption.weight(.semibold))
                                .foregroundStyle(theme.textSecondary.color)
                            Spacer(minLength: 0)
                            Text("Read")
                                .font(Typeface.caption.weight(.semibold))
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(width: 56)
                            Text("Propose")
                                .font(Typeface.caption.weight(.semibold))
                                .foregroundStyle(theme.textSecondary.color)
                                .frame(width: 64)
                        }
                        .padding(.bottom, Space.s2)

                        ForEach(model.orderedGrants) { row in
                            Divider().overlay(theme.shadowDark.color.opacity(0.15))
                            grantRow(row, theme: theme)
                        }
                    }
                    .itemCard()

                    Text("Send, post, pay and delete always stop and ask you, whatever you allow here. Passwords, keys and account settings are never available.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Turn everything off", role: .destructive) {
                        Task { await model.turnEverythingOff() }
                    }
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.danger.color)
                    .disabled(!model.hasAnyGrant)
                    .opacity(model.hasAnyGrant ? 1 : 0.45)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Access")
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

    private func grantRow(_ grant: AIAccessGrant, theme: Theme) -> some View {
        HStack(spacing: Space.s2) {
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(grant.name)
                    .font(Typeface.body.weight(.medium))
                    .foregroundStyle(theme.textPrimary.color)
                Text(usedLabel(grant.lastUsed))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Toggle("Read \(grant.name)", isOn: Binding(
                get: { grant.read },
                set: { enabled in Task { await model.setGrant(grant.module, scope: .read, to: enabled) } }
            ))
            .labelsHidden()
            .tint(theme.accent.color)
            .frame(width: 56)

            if grant.supportsPropose {
                Toggle("Propose \(grant.name)", isOn: Binding(
                    get: { grant.propose },
                    set: { enabled in Task { await model.setGrant(grant.module, scope: .propose, to: enabled) } }
                ))
                .labelsHidden()
                .tint(theme.accent.color)
                .frame(width: 64)
            } else {
                Text("None")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 64)
            }
        }
        .padding(.vertical, Space.s2)
    }

    private func usedLabel(_ date: Date?) -> String {
        guard let date else { return "Never used" }
        return "Used \(date.formatted(.relative(presentation: .named)))"
    }
}
