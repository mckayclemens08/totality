import SwiftUI

/// What a text box holds, which sets its shape.
public enum FieldShape: Sendable {
    /// One line, or a few that grow: a raised capsule.
    case line
    /// A box for paragraphs, such as a signature: the same raised surface with gentler corners.
    case block
}

extension View {
    /// The one look for every text box in Totality: a raised capsule on the background, with no line
    /// around it. The owner chose it on 2026-11-10 for every module. Put it on the field, or on the row
    /// that holds a field and its icons. Inside a Form it clears the row's own background.
    public func raisedField(_ shape: FieldShape = .line) -> some View {
        modifier(RaisedField(shape: shape))
    }
}

private struct RaisedField: ViewModifier {
    let shape: FieldShape

    func body(content: Content) -> some View {
        let corner = shape == .line ? Radius.field : Radius.md
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .frame(minHeight: Space.s7)
            .neumorphic(.raised, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A search box in the raised-field look: a magnifying glass, the words, and a button to clear them.
/// Modules put it above their list in place of the system search bar.
public struct SearchBox: View {
    let prompt: String
    @Binding var text: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    public var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .foregroundStyle(theme.textPrimary.color)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textSecondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(Typeface.body)
        .raisedField()
    }
}
