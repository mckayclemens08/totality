import SwiftUI
import TotalityCore

/// What removing a module says. It hides the module and deletes nothing.
enum HomeRemoval {
    static func message(for module: ModuleEntry) -> String {
        "\(module.keeps) won't be deleted, and \(module.name) comes back as it was if you add it again."
    }
}

/// The minus on a tile's top corner while Home is being edited. Small to look at, a full finger to hit.
struct RemoveTileButton: View {
    let module: ModuleEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(Typeface.caption.weight(.bold))
                .foregroundStyle(Theme.current.textSecondary.color)
                .frame(width: Metric.removeButton, height: Metric.removeButton)
                .neumorphic(.subtle, in: Circle())
                .frame(width: Space.s7, height: Space.s7)
                .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel("Remove \(module.name) from Home")
    }
}

/// The last tile while editing: a way back for the modules that were removed.
struct AddModuleTile: View {
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        Button(action: action) {
            Label("Add module", systemImage: "plus")
                .font(Typeface.callout)
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: width, height: Space.s8)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Home with every module removed: a note and the way back.
struct EmptyHome: View {
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s4) {
            Text("Every module is off Home. Nothing in them was deleted.")
                .font(Typeface.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AddModuleTile(width: width, action: action)
        }
        .frame(width: width)
        .padding(.top, Space.s6)
    }
}

/// The removed modules, each with what it's for. A tap puts it back where it was.
struct AddModulesView: View {
    let modules: [ModuleEntry]
    let onAdd: (ModuleID) -> Void
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.s3) {
                    if modules.isEmpty {
                        Text("Every module is already on Home.")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textSecondary.color)
                            .padding(.top, Space.s6)
                    }
                    ForEach(modules) { module in
                        Button { onAdd(module.id) } label: {
                            HStack(spacing: Space.s3) {
                                Image(systemName: module.systemImage)
                                    .font(Typeface.headline)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .frame(width: Space.s7, height: Space.s7)
                                    .neumorphic(.raised, in: Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: Space.s1) {
                                    Text(module.name)
                                        .font(Typeface.headline)
                                        .foregroundStyle(theme.textPrimary.color)
                                    if !module.summary.isEmpty {
                                        Text(module.summary)
                                            .font(Typeface.caption)
                                            .foregroundStyle(theme.textSecondary.color)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: Space.s2)
                                Image(systemName: "plus.circle.fill")
                                    .font(Typeface.headline)
                                    .foregroundStyle(theme.accent.color)
                                    .accessibilityHidden(true)
                            }
                            .padding(Space.s3)
                            .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(module.name) to Home")
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Add to Home")
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
}
