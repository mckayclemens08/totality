import SwiftUI
import UniformTypeIdentifiers
import TotalityUI

/// One alarm's time, label, days, snooze and sound.
struct AlarmEditor: View {
    let model: ClockModel
    let isNew: Bool
    let onDone: () -> Void
    @State private var alarm: ClockAlarm
    @State private var time: Date

    init(model: ClockModel, alarm: ClockAlarm, isNew: Bool, onDone: @escaping () -> Void) {
        self.model = model
        self.isNew = isNew
        self.onDone = onDone
        _alarm = State(initialValue: alarm)
        _time = State(initialValue: alarm.date ?? timeDate(hour: alarm.hour, minute: alarm.minute, calendar: model.calendar))
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    picker
                    TextField("Label", text: $alarm.label)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .raisedField()
                    Text("This label shows on your Lock Screen when the alarm rings.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                    if alarm.date == nil {
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Text("Repeat · \(ClockMath.repeatText(alarm.weekdays, calendar: model.calendar))").clockHeading()
                            WeekdayPicker(days: $alarm.weekdays, calendar: model.calendar)
                        }
                    }
                    VStack(spacing: Space.s3) {
                        if model.ringsAsAlarm {
                            Toggle("Snooze for 9 minutes", isOn: $alarm.snoozes)
                                .tint(theme.accent.color)
                        }
                        NavigationLink {
                            SoundPicker(model: model, sound: $alarm.sound)
                        } label: {
                            HStack {
                                Text("Sound").foregroundStyle(theme.textPrimary.color)
                                Spacer()
                                Text(model.soundName(alarm.sound)).foregroundStyle(theme.textSecondary.color)
                                Image(systemName: "chevron.right").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                    }
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .itemCard()
                    if let source = alarm.source {
                        ClockNote(systemImage: "link", text: "Set from \(source.title).")
                    }
                    if !isNew {
                        Button("Delete alarm", role: .destructive) {
                            Task { await model.deleteAlarm(alarm.id) }
                            onDone()
                        }
                        .font(Typeface.callout.weight(.semibold))
                        .foregroundStyle(theme.danger.color)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.s2)
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle(isNew ? "New alarm" : "Edit alarm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .tint(theme.accent.color)
    }

    @ViewBuilder private var picker: some View {
        if alarm.date != nil {
            DatePicker("Rings once", selection: $time, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .font(Typeface.body)
                .itemCard()
        } else {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                #if os(iOS)
                .datePickerStyle(.wheel)
                #endif
                .frame(maxWidth: .infinity)
                .itemCard()
        }
    }

    private func save() {
        var saved = alarm
        let parts = model.calendar.dateComponents([.hour, .minute], from: time)
        saved.hour = parts.hour ?? saved.hour
        saved.minute = parts.minute ?? saved.minute
        if saved.date != nil { saved.date = time }
        saved.isOn = true
        Task { await model.save(saved) }
        onDone()
    }
}

/// iOS's sound, Totality's tones, and the person's own.
struct SoundPicker: View {
    let model: ClockModel
    @Binding var sound: ClockSound
    @State private var importing = false

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                VStack(spacing: 0) {
                    row("Standard", .standard)
                    ForEach(ClockTone.allCases, id: \.self) { tone in row(tone.name, .tone(tone)) }
                }
                .itemCard()
                Text("Chime, Pulse and Rise are made on this iPhone from plain tones, so they're free to use.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Text("Your sounds").clockHeading().padding(.top, Space.s2)
                if !model.ownSounds.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.ownSounds) { own in
                            row(own.name, .own(own.id))
                                .contextMenu {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        if sound == .own(own.id) { sound = .standard }
                                        Task { await model.removeSound(own.id) }
                                    }
                                }
                        }
                    }
                    .itemCard()
                }
                ClockButton(title: "Add a sound", systemImage: "plus") { importing = true }
                Text("Your sounds stay on this iPhone, unencrypted, so iOS can play them with Totality closed. Up to 30 seconds is kept.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color)
        .navigationTitle("Sound")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.addSound(from: url, named: url.deletingPathExtension().lastPathComponent) }
        }
    }

    private func row(_ name: String, _ choice: ClockSound) -> some View {
        let theme = Theme.current
        return Button {
            sound = choice
        } label: {
            HStack {
                Text(name).foregroundStyle(theme.textPrimary.color)
                Spacer()
                if sound == choice {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent.color).accessibilityLabel("Chosen")
                }
            }
            .font(Typeface.body)
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPress())
    }
}

/// Bedtime and wake-up: the wake-up rings as an alarm, the reminder before bed is a notification.
struct BedtimeSheet: View {
    let model: ClockModel
    let onDone: () -> Void
    @State private var sleep: SleepSchedule
    @State private var bed: Date
    @State private var wake: Date

    init(model: ClockModel, sleep: SleepSchedule, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _sleep = State(initialValue: sleep)
        _bed = State(initialValue: timeDate(hour: sleep.bedHour, minute: sleep.bedMinute, calendar: model.calendar))
        _wake = State(initialValue: timeDate(hour: sleep.wakeHour, minute: sleep.wakeMinute, calendar: model.calendar))
    }

    var body: some View {
        let theme = Theme.current
        let current = updated
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Toggle("Bedtime and wake-up", isOn: $sleep.isOn)
                        .font(Typeface.headline)
                        .tint(theme.accent.color)
                        .itemCard()
                    VStack(alignment: .leading, spacing: Space.s1 / 2) {
                        Text("Sleep").font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.textSecondary.color)
                        Text(ClockMath.length(current.sleepMinutes * 60))
                            .font(Typeface.title.weight(.bold))
                            .foregroundStyle(theme.textPrimary.color)
                    }
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectionWash(true, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    VStack(spacing: Space.s3) {
                        DatePicker("Bedtime", selection: $bed, displayedComponents: .hourAndMinute)
                        DatePicker("Wake up", selection: $wake, displayedComponents: .hourAndMinute)
                    }
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .itemCard()
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Wake-up days").clockHeading()
                        WeekdayPicker(days: $sleep.weekdays, calendar: model.calendar)
                    }
                    VStack(spacing: Space.s3) {
                        Picker("Remind me before bed", selection: $sleep.remindMinutes) {
                            ForEach([0, 15, 30, 45, 60], id: \.self) { minutes in
                                Text(minutes == 0 ? "At bedtime" : "\(minutes) min").tag(minutes)
                            }
                        }
                        NavigationLink {
                            SoundPicker(model: model, sound: $sleep.sound)
                        } label: {
                            HStack {
                                Text("Wake-up sound").foregroundStyle(theme.textPrimary.color)
                                Spacer()
                                Text(model.soundName(sleep.sound)).foregroundStyle(theme.textSecondary.color)
                                Image(systemName: "chevron.right").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                            }
                        }
                    }
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                    .itemCard()
                    Text(model.ringsAsAlarm
                         ? "The wake-up rings as an alarm. The bedtime reminder is a notification, so the silent switch mutes it."
                         : "On \(SystemAlarms.systemName) the wake-up and the bedtime reminder both come as notifications, which the silent switch mutes.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Bedtime")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = updated
                        Task { await model.save(saved) }
                        onDone()
                    }
                }
            }
        }
        .tint(theme.accent.color)
    }

    private var updated: SleepSchedule {
        var value = sleep
        let bedParts = model.calendar.dateComponents([.hour, .minute], from: bed)
        let wakeParts = model.calendar.dateComponents([.hour, .minute], from: wake)
        value.bedHour = bedParts.hour ?? value.bedHour
        value.bedMinute = bedParts.minute ?? value.bedMinute
        value.wakeHour = wakeParts.hour ?? value.wakeHour
        value.wakeMinute = wakeParts.minute ?? value.wakeMinute
        return value
    }
}
