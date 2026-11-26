import SwiftUI
import TotalityCore
import TotalityUI

/// When an alert rings: the start minus its offset, or for an all-day event the all-day hour of that day
/// minus it.
enum AlertTime {
    static func ring(_ minutes: Int, start: Date, isAllDay: Bool, allDayMinute: Int, display: Calendar) -> Date {
        let moment: Date
        if isAllDay {
            let begin = CalendarDay(start, in: display).start(in: display)
            moment = display.date(byAdding: .minute, value: allDayMinute, to: begin) ?? begin
        } else {
            moment = start
        }
        return moment.addingTimeInterval(-Double(minutes) * 60)
    }
}

/// The editor's Alerts section: each alert is a row that can be removed, with Add alert under them. Up to
/// five. Used for Totality's events and, kept on this iPhone only, for Google's.
struct AlertsSection: View {
    @Binding var alerts: [Int]
    let isAllDay: Bool
    let start: Date
    let display: Calendar
    let allDayMinute: Int
    let footer: String
    @State private var adding = false

    var body: some View {
        let theme = Theme.current
        Section {
            ForEach(AlertOffset.sorted(alerts), id: \.self) { minutes in
                HStack(spacing: Space.s3) {
                    Image(systemName: "bell")
                        .foregroundStyle(theme.accent.color)
                    VStack(alignment: .leading, spacing: Space.hairline * 2) {
                        Text(AlertOffset.name(minutes, allDay: isAllDay))
                            .font(Typeface.body)
                            .foregroundStyle(theme.textPrimary.color)
                        Text(AlertTime.ring(minutes, start: start, isAllDay: isAllDay, allDayMinute: allDayMinute, display: display)
                            .formatted(date: .abbreviated, time: .shortened))
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer()
                    Button {
                        alerts.removeAll { $0 == minutes }
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(minWidth: Metric.headerButton, minHeight: Metric.headerButton)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(AlertOffset.name(minutes, allDay: isAllDay))")
                }
            }
            if alerts.count < AlertOffset.maxPerEvent {
                Button { adding = true } label: {
                    Label("Add alert", systemImage: "plus")
                }
                .foregroundStyle(theme.accent.color)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text(alerts.count >= AlertOffset.maxPerEvent ? footer + " Up to \(AlertOffset.maxPerEvent) alerts per event." : footer)
        }
        .sheet(isPresented: $adding) {
            AddAlertSheet(existing: alerts, isAllDay: isAllDay, start: start, display: display, allDayMinute: allDayMinute) { minutes in
                alerts = AlertOffset.adding(minutes, to: alerts)
                adding = false
            } onCancel: {
                adding = false
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Presets are one tap. Custom takes a number and a unit and says exactly when it would ring. Presets the
/// event already has are dimmed, so none is added twice.
struct AddAlertSheet: View {
    let existing: [Int]
    let isAllDay: Bool
    let start: Date
    let display: Calendar
    let allDayMinute: Int
    let onAdd: (Int) -> Void
    let onCancel: () -> Void
    @State private var custom = false
    @State private var amount = 3
    @State private var unit: AlertOffset.Unit = .days

    private var customMinutes: Int? { AlertOffset.custom(amount, unit) }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.s2)], alignment: .leading, spacing: Space.s2) {
                        ForEach(AlertOffset.presets(allDay: isAllDay), id: \.self) { minutes in
                            let used = existing.contains(minutes)
                            FilterPill(Self.short(minutes, allDay: isAllDay), isSelected: false) { onAdd(minutes) }
                                .disabled(used)
                                .opacity(used ? 0.55 : 1)
                                .accessibilityHint(used ? "Already added" : "")
                        }
                        FilterPill("Custom", isSelected: custom) { custom.toggle() }
                    }
                    if custom {
                        VStack(alignment: .leading, spacing: Space.s3) {
                            Stepper(value: $amount, in: 1...999) {
                                Text("Amount: \(amount)")
                                    .font(Typeface.body)
                                    .foregroundStyle(theme.textPrimary.color)
                            }
                            FilterPills(AlertOffset.Unit.allCases, selection: $unit) { $0.rawValue }
                            if let minutes = customMinutes {
                                let when = AlertTime.ring(minutes, start: start, isAllDay: isAllDay, allDayMinute: allDayMinute, display: display)
                                Text("Rings \(when.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Typeface.callout)
                                    .foregroundStyle(theme.textPrimary.color)
                                Text(AlertOffset.name(minutes, allDay: isAllDay))
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                            } else {
                                Text("Alerts can ring up to four weeks ahead.")
                                    .font(Typeface.caption)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .padding(Space.s4)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Add alert")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back", action: onCancel) }
                if custom {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { if let minutes = customMinutes, !existing.contains(minutes) { onAdd(minutes) } }
                            .disabled(customMinutes == nil || existing.contains(customMinutes ?? -1))
                    }
                }
            }
        }
        .tint(theme.accent.color)
    }

    /// "At the start", "5 min", "1 day"... short enough for a pill.
    static func short(_ minutes: Int, allDay: Bool) -> String {
        if minutes == 0 { return allDay ? "On the day" : "At the start" }
        let long = AlertOffset.name(minutes, allDay: allDay)
        return long.replacingOccurrences(of: " before", with: "")
            .replacingOccurrences(of: " minutes", with: " min").replacingOccurrences(of: " minute", with: " min")
    }
}

extension View {
    /// Inline titles exist on iPhone only.
    @ViewBuilder fileprivate func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
