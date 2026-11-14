import SwiftUI
import TotalityUI

/// Find and replace, drawn natively above the page. The page highlights every match.
struct WritingFindBar: View {
    let controller: WritingEditorController
    let onClose: () -> Void

    @State private var query = ""
    @State private var replacement = ""
    @State private var showsReplace = false
    @State private var caseSensitive = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textSecondary.color)
                        .accessibilityHidden(true)
                    TextField("Find in doc", text: $query)
                        .focused($queryFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { step("findNext") }
                    Text(Self.position(controller.matches, hasQuery: !query.isEmpty))
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .monospacedDigit()
                }
                .raisedField()
                ToolbarIcon("Previous match", systemImage: "chevron.up", isEnabled: controller.matches.count > 0) { step("findPrevious") }
                ToolbarIcon("Next match", systemImage: "chevron.down", isEnabled: controller.matches.count > 0) { step("findNext") }
            }
            if showsReplace {
                HStack(spacing: Space.s2) {
                    TextField("Replace with", text: $replacement)
                        .autocorrectionDisabled()
                        .raisedField()
                    Button("Replace") { step("replace") }
                        .disabled(controller.matches.count == 0)
                    Button("All") { step("replaceAll") }
                        .disabled(controller.matches.count == 0)
                }
                .font(Typeface.callout)
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent.color)
            }
            HStack(spacing: Space.s4) {
                Toggle("Match case", isOn: $caseSensitive)
                    .toggleStyle(.button)
                Button(showsReplace ? "Hide replace" : "Replace…") { showsReplace.toggle() }
                Spacer()
                Button("Done", action: close)
            }
            .font(Typeface.caption)
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .onAppear { queryFocused = true }
        .task(id: [query, replacement, caseSensitive ? "1" : "0"]) {
            await controller.find(query, replacement: replacement, caseSensitive: caseSensitive)
        }
    }

    /// "3 of 12", or how many there are before one is selected.
    nonisolated static func position(_ matches: WritingMatches, hasQuery: Bool) -> String {
        guard hasQuery else { return "" }
        if matches.count == 0 { return "None" }
        if matches.current == 0 { return matches.count == 1 ? "1 match" : "\(matches.count.formatted()) matches" }
        return "\(matches.current.formatted()) of \(matches.count.formatted())"
    }

    private func step(_ command: String) {
        Task { await controller.findStep(command) }
    }

    private func close() {
        controller.closeFind()
        onClose()
    }
}

/// The doc's headings. A tap goes there, and a heading's chevron folds its section on the page.
struct WritingOutline: View {
    let headings: [WritingHeading]
    let onJump: (WritingHeading) -> Void
    let onFold: (WritingHeading) -> Void

    @State private var folded: Set<Int> = []

    var body: some View {
        let theme = Theme.current
        Group {
            if headings.isEmpty {
                ReaderMessage(
                    systemImage: "list.bullet.indent",
                    title: "No headings yet",
                    detail: "Start a line with # for a heading, or use H1 to H3 on the format bar. Headings show here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s1) {
                        ForEach(headings) { heading in
                            HStack(spacing: Space.s2) {
                                Button {
                                    onJump(heading)
                                } label: {
                                    Text(heading.text.isEmpty ? "Untitled heading" : heading.text)
                                        .font(heading.level == 1 ? Typeface.headline : Typeface.body)
                                        .foregroundStyle(heading.level <= 2 ? theme.textPrimary.color : theme.textSecondary.color)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button {
                                    if folded.contains(heading.from) { folded.remove(heading.from) } else { folded.insert(heading.from) }
                                    onFold(heading)
                                } label: {
                                    Image(systemName: folded.contains(heading.from) ? "chevron.right" : "chevron.down")
                                        .font(Typeface.caption)
                                        .foregroundStyle(theme.textSecondary.color)
                                        .frame(width: Space.s6, height: Space.s6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(folded.contains(heading.from) ? "Show section" : "Fold section")
                            }
                            .padding(.leading, CGFloat(heading.level - 1) * Space.s4)
                            .padding(.vertical, Space.s1)
                        }
                    }
                    .padding(Space.s4)
                }
            }
        }
        .background(theme.bg.color)
        .onChange(of: headings) { folded.formIntersection(headings.map(\.from)) }
    }
}

/// Words in the doc, the section and the selection, and how far along the targets are.
struct WritingCountsLine: View {
    let stats: WritingStats
    let docTarget: Int?
    let goals: WritingGoals

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Text(Self.summary(stats, docTarget: docTarget))
            Spacer(minLength: 0)
            if goals.dailyTarget > 0 {
                Text("Today \(goals.written.formatted()) of \(goals.dailyTarget.formatted())")
                ProgressView(value: WritingGoals.progress(goals.written, of: goals.dailyTarget) ?? 0)
                    .frame(width: Space.s7)
                    .tint(theme.accent.color)
                    .accessibilityLabel("Today's goal")
            }
        }
        .font(Typeface.caption)
        .foregroundStyle(theme.textSecondary.color)
        .monospacedDigit()
        .padding(.horizontal, Space.s4)
    }

    nonisolated static func summary(_ stats: WritingStats, docTarget: Int?) -> String {
        var parts = [docTarget.map { "\(stats.words.formatted()) of \($0.formatted()) words" } ?? words(stats.words)]
        if stats.section > 0, stats.section != stats.words { parts.append("section \(stats.section.formatted())") }
        if stats.selection > 0 { parts.append("\(stats.selection.formatted()) selected") }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count.formatted()) words"
    }
}

/// How the page looks and behaves, and the doc's and the day's word targets.
struct WritingSettingsSheet: View {
    @Binding var settings: WritingSettings
    @Binding var dailyTarget: Int
    let docTarget: Int?
    let onDocTarget: (Int?) -> Void

    @State private var docTargetText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Focus mode", isOn: $settings.focus)
                    Toggle("Typewriter scrolling", isOn: $settings.typewriter)
                    Toggle("Smart quotes and dashes", isOn: $settings.smartPunctuation)
                    Picker("Font", selection: $settings.serif) {
                        Text("Sans serif").tag(false)
                        Text("Serif").tag(true)
                    }
                } footer: {
                    Text("Focus mode fades everything but the paragraph you're writing. Typewriter scrolling keeps that line in the middle of the screen.")
                }
                Section {
                    TextField("Words for this doc", text: $docTargetText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onSubmit(saveDocTarget)
                    Stepper("Each day: \(dailyTarget == 0 ? "no goal" : "\(dailyTarget.formatted()) words")", value: $dailyTarget, in: 0...20_000, step: 250)
                } header: {
                    Text("Targets")
                } footer: {
                    Text("The doc's target is sealed with the doc. The daily goal counts words you add on this device, in any doc.")
                }
            }
            .navigationTitle("Writing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveDocTarget()
                        dismiss()
                    }
                }
            }
            .onAppear { docTargetText = docTarget.map(String.init) ?? "" }
        }
    }

    private func saveDocTarget() {
        let digits = docTargetText.filter(\.isNumber)
        let target = Int(digits).flatMap { $0 > 0 ? $0 : nil }
        if target != docTarget { onDocTarget(target) }
    }
}
