import SwiftUI
import TotalityCore

/// "Set an alarm" from any module, like "wake me for this flight" on a Calendar event (issue 204). The
/// module hands over a draft and the registry's alarm maker; nothing is set until Set.
public struct SetAlarmSheet: View {
    private let draft: AlarmDraft
    private let maker: (any AlarmMaker)?
    private let onDone: (AlarmMade?) -> Void
    @State private var label: String
    @State private var time: Date
    @State private var isSaving = false
    @State private var failed = false

    public init(draft: AlarmDraft, maker: (any AlarmMaker)?, onDone: @escaping (AlarmMade?) -> Void) {
        self.draft = draft
        self.maker = maker
        self.onDone = onDone
        _label = State(initialValue: draft.label)
        _time = State(initialValue: draft.fireDate)
    }

    public var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    TextField("Label", text: $label)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .raisedField()
                    DatePicker("Rings once", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .itemCard()
                    Text("This label shows on your Lock Screen when the alarm rings. The alarm keeps a link back to \(draft.source?.title ?? "where it came from").")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    if failed {
                        Text("This alarm couldn't be set. Check that Totality may ring alarms in Settings.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Set an alarm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { Task { await set() } }
                        .disabled(isSaving || maker == nil || time <= Date())
                }
            }
        }
        .tint(theme.accent.color)
        .presentationDetents([.medium, .large])
    }

    private func set() async {
        guard let maker else { return }
        isSaving = true
        defer { isSaving = false }
        var draft = draft
        draft.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.fireDate = time
        do {
            onDone(try await maker.makeAlarm(draft))
        } catch {
            failed = true
        }
    }
}

extension View {
    /// Shows the Set an alarm sheet while `draft` is set, and says what happened with `onSet`.
    public func setAlarmSheet(
        _ draft: Binding<AlarmDraft?>, maker: (any AlarmMaker)?, onSet: @escaping (AlarmMade) -> Void
    ) -> some View {
        sheet(item: draft) { item in
            SetAlarmSheet(draft: item, maker: maker) { made in
                draft.wrappedValue = nil
                if let made { onSet(made) }
            }
        }
    }
}
