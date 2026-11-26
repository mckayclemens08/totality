import SwiftUI
import TotalityCore
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Account › Notifications (issue 232, mockup on the PR): a switch per module and per kind, quiet hours,
/// grouping, previews and badges. Everything here stays on this device.
public struct NotificationsSettingsView: View {
    @Bindable private var hub: NotificationHub
    @State private var permission: UNAuthorizationStatus?

    public init(hub: NotificationHub = .shared) {
        self.hub = hub
    }

    private static let names: [ModuleID: String] = [
        .social: "Social", .messages: "Messages", .mail: "Mail", .tasks: "Tasks", .calendar: "Calendar",
    ]
    private static let icons: [ModuleID: String] = [
        .social: "person.2", .messages: "bubble.left.and.bubble.right", .mail: "envelope", .tasks: "checklist",
        .calendar: "calendar",
    ]

    public var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s5) {
                Text("Alerts are written on this iPhone. Totality's server only says \u{201C}look again\u{201D}, never what happened.")
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)

                if permission == .denied {
                    permissionCard
                }

                ForEach(modules, id: \.self) { module in
                    moduleCard(module)
                    if module == .calendar, hub.preferences.isOn(module) { calendarDefaults }
                }

                group("Quiet hours") {
                    toggle("Quiet hours", detail: nil, isOn: $hub.preferences.quietHoursOn)
                    if hub.preferences.quietHoursOn {
                        HStack(spacing: Space.s3) {
                            timePicker("From", minutes: $hub.preferences.quietStart)
                            timePicker("Until", minutes: $hub.preferences.quietEnd)
                        }
                        .padding(.horizontal, Space.s4)
                        .padding(.bottom, Space.s2)
                        note("Alerts still arrive, quietly in Notification Centre, with no sound or banner. Task reminders ring as usual. Calendar alerts arrive quietly.")
                        toggle("Close friends break through", detail: "Their messages and posts ring even in quiet hours",
                               isOn: $hub.preferences.closeFriendsBreakThrough)
                    }
                }

                group("On the lock screen") {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Group alerts")
                            .font(Typeface.body)
                            .foregroundStyle(theme.textPrimary.color)
                        FilterPills(NotificationPreferences.Grouping.allCases, selection: $hub.preferences.grouping) { $0.name }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                    toggle("Show message text", detail: "For encrypted messages and Close-friends posts. Off shows only who it's from.",
                           isOn: $hub.preferences.showsPrivateText)
                }

                note("These settings stay on this iPhone. iOS's own Settings › Totality can still turn every alert off.")
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.bg.color)
        .navigationTitle("Notifications")
        .task {
            permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            await hub.updateBadge()
        }
        .onChange(of: hub.preferences) { Task { await hub.updateBadge() } }
    }

    private var modules: [ModuleID] {
        var seen: [ModuleID] = []
        for kind in hub.kinds where !seen.contains(kind.module) { seen.append(kind.module) }
        return seen
    }

    private func moduleCard(_ module: ModuleID) -> some View {
        let theme = Theme.current
        let on = Binding(get: { hub.preferences.isOn(module) }, set: { hub.preferences.set(module, on: $0) })
        return VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: on) {
                Label(Self.names[module] ?? module.rawValue.capitalized, systemImage: Self.icons[module] ?? "bell")
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
            }
            .tint(theme.accent.color)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            if on.wrappedValue {
                ForEach(hub.kinds.filter { $0.module == module }) { kind in
                    toggle(kind.name, detail: kind.detail, isOn: Binding(
                        get: { hub.preferences.isOn(kind) }, set: { hub.preferences.set(kind, on: $0) }
                    ))
                    .padding(.leading, Space.s5)
                }
                if hub.sources[module] != nil {
                    toggle("Badge on the app icon", detail: nil, isOn: Binding(
                        get: { hub.preferences.badges(module) }, set: { hub.preferences.setBadges(module, on: $0) }
                    ))
                    .padding(.leading, Space.s5)
                }
            }
        }
        .padding(.vertical, Space.s1)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    // MARK: Calendar defaults

    private var eventAlertsOn: Bool { hub.preferences.isOn(NotificationHub.reminderKinds[1]) }

    /// What new events start with, and the hour all-day alerts ring. Existing events keep their own.
    @ViewBuilder private var calendarDefaults: some View {
        let theme = Theme.current
        defaultAlerts("Default alerts \u{B7} timed events", list: $hub.preferences.calendarAlerts.timed, allDay: false)
        defaultAlerts("Default alerts \u{B7} all-day events", list: $hub.preferences.calendarAlerts.allDay, allDay: true)
        group("All-day alerts") {
            DatePicker("All-day alerts ring at", selection: allDayTime, displayedComponents: .hourAndMinute)
                .font(Typeface.body)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .frame(minHeight: Metric.headerButton)
            note("Applies to events you create from now on. Events you already have keep their alerts. Quiet hours still apply.")
        }
        if !eventAlertsOn {
            note("Event alerts are off. Turn them on above so new events ring.")
        }
    }

    private var allDayTime: Binding<Date> {
        Binding(
            get: {
                let minute = hub.preferences.calendarAlerts.allDayMinute
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                hub.preferences.calendarAlerts.allDayMinute = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private func defaultAlerts(_ title: String, list: Binding<[Int]>, allDay: Bool) -> some View {
        let theme = Theme.current
        let hour = AlertOffset.clock(hub.preferences.calendarAlerts.allDayMinute)
        return group(title) {
            if list.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: Space.hairline * 2) {
                    Text("None")
                        .font(Typeface.body)
                        .foregroundStyle(theme.textSecondary.color)
                    Text("New events won't ring")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .frame(minHeight: Metric.headerButton, alignment: .leading)
            }
            ForEach(AlertOffset.sorted(list.wrappedValue), id: \.self) { minutes in
                HStack {
                    VStack(alignment: .leading, spacing: Space.hairline * 2) {
                        Text(AlertOffset.name(minutes, allDay: allDay))
                            .font(Typeface.body)
                            .foregroundStyle(theme.textPrimary.color)
                        if allDay {
                            Text("at \(hour)")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    Spacer()
                    Button {
                        list.wrappedValue.removeAll { $0 == minutes }
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(minWidth: Metric.headerButton, minHeight: Metric.headerButton)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(AlertOffset.name(minutes, allDay: allDay))")
                }
                .padding(.horizontal, Space.s4)
            }
            if list.wrappedValue.count < AlertOffset.maxPerEvent {
                Menu {
                    ForEach(AlertOffset.presets(allDay: allDay).filter { !list.wrappedValue.contains($0) }, id: \.self) { minutes in
                        Button(AlertOffset.name(minutes, allDay: allDay)) {
                            list.wrappedValue = AlertOffset.adding(minutes, to: list.wrappedValue)
                        }
                    }
                } label: {
                    Label("Add default alert", systemImage: "plus")
                        .font(Typeface.callout)
                        .foregroundStyle(theme.accent.color)
                        .frame(minHeight: Metric.headerButton)
                }
                .padding(.horizontal, Space.s4)
            }
        }
    }

    private var permissionCard: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("Notifications are off for Totality")
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text("Nothing here can ring until they're allowed in iOS Settings.")
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
            #if canImport(UIKit)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.accent.color)
            .frame(minHeight: Metric.headerButton)
            #endif
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title)
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
                .padding(.horizontal, Space.s1)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, Space.s1)
                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private func toggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        let theme = Theme.current
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Space.hairline * 2) {
                Text(title)
                    .font(Typeface.body)
                    .foregroundStyle(theme.textPrimary.color)
                if let detail {
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
        .tint(theme.accent.color)
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .frame(minHeight: Metric.headerButton)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typeface.caption)
            .foregroundStyle(Theme.current.textSecondary.color)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
    }

    private func timePicker(_ title: String, minutes: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
        return DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
            .font(Typeface.callout)
            .foregroundStyle(Theme.current.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
