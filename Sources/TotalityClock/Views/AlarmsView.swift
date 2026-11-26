import SwiftUI
import TotalityUI
#if canImport(UIKit)
import UIKit
#endif

/// Alarms, as the mockup draws them: the next one at the top, then each alarm with its switch.
struct AlarmsView: View {
    let model: ClockModel
    @State private var editing: ClockAlarm?
    @State private var bedtime = false

    var body: some View {
        let alarms = model.alarms
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(spacing: Space.s3) {
                    status
                    if let next = model.nextAlarm {
                        NextAlarm(alarm: next.alarm, date: next.date, now: context.date, calendar: model.calendar)
                    }
                    BedtimeCard(model: model) { bedtime = true }
                    if alarms.isEmpty {
                        ClockEmpty(
                            title: "No alarms yet",
                            detail: model.ringsAsAlarm
                                ? "Totality asks once to ring alarms on your Lock Screen."
                                : "Totality asks once to send notifications for your alarms.",
                            button: "Add an alarm"
                        ) { editing = newAlarm }
                    }
                    ForEach(alarms) { alarm in
                        AlarmRow(model: model, alarm: alarm) { editing = alarm }
                    }
                    notes
                }
                .padding(Space.s4)
                .padding(.bottom, Metric.addButton + Space.s5)
            }
        }
        .addButton("New alarm") { editing = newAlarm }
        .sheet(item: $editing) { alarm in
            AlarmEditor(model: model, alarm: alarm, isNew: !model.alarms.contains { $0.id == alarm.id }) { editing = nil }
        }
        .sheet(isPresented: $bedtime) {
            BedtimeSheet(model: model, sleep: model.device.sleep) { bedtime = false }
        }
    }

    private var newAlarm: ClockAlarm {
        ClockAlarm(hour: 7, minute: 0)
    }

    /// Section 7's errors: access turned off, or an iOS without AlarmKit.
    @ViewBuilder private var status: some View {
        let theme = Theme.current
        if model.access == .denied {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(model.ringsAsAlarm ? "Totality can't ring alarms. Turn it on in Settings." : "Totality can't send alarm notifications. Turn them on in Settings.")
                    .font(Typeface.callout)
                    .foregroundStyle(theme.textPrimary.color)
                #if os(iOS)
                ClockButton(title: "Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            }
            .itemCard()
        }
        if !model.ringsAsAlarm {
            ClockNote(
                systemImage: "exclamationmark.triangle",
                text: "Alarms need iOS 26. Your iPhone is on \(SystemAlarms.systemName), so these come as notifications, which the silent switch mutes and Focus can hold back."
            )
            .padding(.horizontal, Space.s2)
        }
    }

    private var notes: some View {
        VStack(spacing: Space.s2) {
            if model.ringsAsAlarm {
                ClockNote(systemImage: "bell", text: "Alarms ring through silent mode and Focus.")
            }
            ClockNote(systemImage: "lock", text: "Labels are encrypted here, and show on your Lock Screen when an alarm rings. Alarms stay on this iPhone.")
        }
        .padding(.horizontal, Space.s2)
        .padding(.top, Space.s2)
    }
}

private struct NextAlarm: View {
    let alarm: ClockAlarm
    let date: Date
    let now: Date
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s1 / 2) {
            Text("Next alarm").font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textSecondary.color)
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(Typeface.title.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                Text(ClockMath.until(date, from: now))
                    .font(Typeface.callout.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
            }
            if !alarm.label.isEmpty {
                Text(alarm.label).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionWash(true, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct AlarmRow: View {
    let model: ClockModel
    let alarm: ClockAlarm
    let onEdit: () -> Void

    var body: some View {
        let theme = Theme.current
        let parts = timeParts(hour: alarm.hour, minute: alarm.minute, calendar: model.calendar)
        let failed = model.failed.contains(alarm.id)
        HStack(spacing: Space.s3) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                        Text(parts.time).font(.system(size: Space.s6 - Space.s1 / 2, weight: .semibold)).monospacedDigit()
                        Text(parts.suffix).font(Typeface.callout)
                    }
                    .foregroundStyle(alarm.isOn ? theme.textPrimary.color : theme.textSecondary.color)
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(2)
                    if failed {
                        Label("Not set. iOS didn't take this alarm.", systemImage: "exclamationmark.triangle.fill")
                            .font(Typeface.caption.weight(.semibold))
                            .foregroundStyle(theme.danger.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            Toggle(isOn: Binding(get: { alarm.isOn }, set: { on in Task { await model.setOn(alarm.id, on) } })) {
                Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
            }
            .labelsHidden()
            .tint(theme.accent.color)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteAlarm(alarm.id) } }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !alarm.label.isEmpty { parts.append(alarm.label) }
        if let date = alarm.date {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        } else {
            parts.append(ClockMath.repeatText(alarm.weekdays, calendar: model.calendar))
        }
        return parts.joined(separator: " · ")
    }
}

/// Bedtime and wake-up's card at the top of Alarms.
private struct BedtimeCard: View {
    let model: ClockModel
    let onOpen: () -> Void

    var body: some View {
        let theme = Theme.current
        let sleep = model.device.sleep
        Button(action: onOpen) {
            HStack(spacing: Space.s3) {
                Image(systemName: "bed.double")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1 / 2) {
                    Text("Bedtime and wake-up").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                    Text(sleep.isOn ? summary(sleep) : "Off. Set a bedtime reminder and a wake-up alarm.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            .itemCard()
        }
        .buttonStyle(SoftPress())
    }

    private func summary(_ sleep: SleepSchedule) -> String {
        let bed = timeParts(hour: sleep.bedHour, minute: sleep.bedMinute, calendar: model.calendar)
        let wake = timeParts(hour: sleep.wakeHour, minute: sleep.wakeMinute, calendar: model.calendar)
        return "Bed \(bed.time) \(bed.suffix), up \(wake.time) \(wake.suffix), \(ClockMath.repeatText(sleep.weekdays, calendar: model.calendar).lowercased())"
    }
}
