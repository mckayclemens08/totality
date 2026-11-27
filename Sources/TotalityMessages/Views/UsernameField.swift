import SwiftUI
import TotalityCore
import TotalityUI

/// The one place a person types Totality usernames: a fixed "@" so nobody types it, and tappable
/// suggestions as they type, so nobody has to guess a username. New message, new group, new channel and
/// every "add people" screen use it. `multiple` is for a list separated by commas.
struct UsernameField: View {
    let people: MessagesPeople
    @Binding var text: String
    var placeholder = "username"
    var label = "Their username"
    var multiple = false
    /// Usernames never suggested, such as people already in the chat.
    var excluded: Set<String> = []
    var autofocus = false
    /// Suggests only people who follow you, for a broadcast channel.
    var followersOnly = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var found: [ProfileSuggestion] = []
    /// The suggestion just tapped, so the list closes instead of offering the same person again.
    @State private var picked: String?

    var body: some View {
        let theme = Theme.current
        let token = UsernameTyping.currentToken(text)
        let shown = token == picked ? [] : UsernameTyping.shown(found, typing: token, excluding: excluded.union(UsernameTyping.finished(text)))
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                // The @ is already there, so people type only the name.
                Text("@").foregroundStyle(theme.textSecondary.color).accessibilityHidden(true)
                TextField(placeholder, text: $text, axis: multiple ? .vertical : .horizontal)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .lineLimit(multiple ? 1...4 : 1...1)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(label)
            }
            .font(Typeface.body)
            .raisedField()
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(shown) { person in
                        Button { choose(person) } label: { SuggestionRow(person: person) }
                            .buttonStyle(SoftPress())
                    }
                }
                .padding(.vertical, Space.s1)
                .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
        .onAppear { if autofocus { focused = true } }
        .onChange(of: text) { if token != picked { picked = nil } }
        .task(id: token) {
            guard !token.isEmpty else { found = []; return }
            // Wait for a pause in typing, so each letter isn't a request.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let answer = followersOnly ? await people.followerSuggestions(for: token) : await people.suggestions(for: token)
            if !Task.isCancelled { found = answer }
        }
    }

    private func choose(_ person: ProfileSuggestion) {
        text = UsernameTyping.replacingCurrent(in: text, with: person.handle, multiple: multiple)
        picked = multiple ? nil : person.handle
        found = []
        focused = true
    }
}

private struct SuggestionRow: View {
    let person: ProfileSuggestion

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Initial(name: person.displayName ?? person.handle)
            VStack(alignment: .leading, spacing: 0) {
                Text("@\(person.handle)")
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                if let name = person.displayName, !name.isEmpty {
                    Text(name)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(person.displayName.map { "\($0), @\(person.handle)" } ?? "@\(person.handle)")
        .accessibilityHint("Adds them")
    }
}
