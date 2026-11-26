import SwiftUI
import TotalityUI

/// Cities you added, each with its time, the day when it differs, and how far ahead or behind it is.
struct WorldClockView: View {
    let model: ClockModel
    @State private var adding = false

    var body: some View {
        let cities = model.items.shownCities
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(spacing: Space.s3) {
                    if cities.isEmpty {
                        ClockEmpty(title: "No cities yet", detail: "Add a city to see its time.", button: "Add a city") { adding = true }
                    }
                    ForEach(cities) { city in
                        CityRow(city: city, now: context.date, calendar: model.calendar)
                            .contextMenu {
                                if let index = cities.firstIndex(of: city) {
                                    if index > 0 {
                                        Button("Move up", systemImage: "arrow.up") {
                                            Task { await model.moveCities(from: [index], to: index - 1) }
                                        }
                                    }
                                    if index < cities.count - 1 {
                                        Button("Move down", systemImage: "arrow.down") {
                                            Task { await model.moveCities(from: [index], to: index + 2) }
                                        }
                                    }
                                }
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    Task { await model.removeCity(city.id) }
                                }
                            }
                    }
                    if !cities.isEmpty {
                        ClockNote(systemImage: "lock", text: "Your cities are encrypted on this iPhone before they sync. Daylight saving comes from the iPhone's own time zone data.")
                            .padding(.horizontal, Space.s2)
                    }
                }
                .padding(Space.s4)
                .padding(.bottom, Metric.addButton + Space.s5)
            }
        }
        .addButton("Add a city") { adding = true }
        .sheet(isPresented: $adding) {
            CityPicker { choice in
                adding = false
                if let choice { Task { await model.addCity(choice) } }
            }
        }
    }
}

private struct CityRow: View {
    let city: WorldCity
    let now: Date
    let calendar: Calendar

    var body: some View {
        let theme = Theme.current
        let zone = city.timeZone ?? .current
        let parts = cityTime(city, at: now, calendar: calendar)
        let day = ClockMath.dayWord(in: zone, local: calendar.timeZone, at: now)
        let offset = ClockMath.offset(of: zone, from: calendar.timeZone, at: now)
        return HStack(alignment: .center, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(city.name)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                Text([day ?? "Today", offset].joined(separator: " · "))
                    .font(Typeface.caption)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                Text(parts.time).font(.system(size: Space.s6, weight: .semibold)).monospacedDigit()
                Text(parts.suffix).font(Typeface.callout)
            }
            .foregroundStyle(theme.textPrimary.color)
        }
        .itemCard()
        .accessibilityElement(children: .combine)
    }
}

/// Every city the iPhone knows, searched on the device.
struct CityPicker: View {
    let onDone: (CityList.Choice?) -> Void
    @State private var query = ""

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            VStack(spacing: Space.s3) {
                SearchBox("City or region", text: $query)
                    .padding(.horizontal, Space.s4)
                List(CityList.search(query)) { choice in
                    Button {
                        onDone(choice)
                    } label: {
                        VStack(alignment: .leading, spacing: Space.s1 / 2) {
                            Text(choice.name).foregroundStyle(theme.textPrimary.color)
                            Text(choice.region).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    .listRowBackground(theme.bg.color)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.top, Space.s2)
            .background(theme.bg.color)
            .navigationTitle("Add a city")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
            }
        }
        .tint(theme.accent.color)
    }
}
