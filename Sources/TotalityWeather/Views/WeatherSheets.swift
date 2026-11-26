import SwiftUI
import TotalityCore
import TotalityUI
#if canImport(MapKit)
import MapKit
#endif

/// The saved places in the person's order, where they're reordered and removed, with a search above
/// for adding a city. Only the words typed go to the search; where the person is never does.
struct PlacesSheet: View {
    @Bindable var model: WeatherModel
    let onDone: () -> Void
    @State private var query = ""
    @State private var found: [WeatherPlace] = []
    @State private var searchProblem: String?
    @State private var searching = false

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            List {
                Section {
                    SearchBox("Search for a city", text: $query)
                    if let searchProblem {
                        Text(searchProblem)
                            .font(Typeface.caption)
                            .foregroundStyle(theme.danger.color)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(found) { place in
                        Button {
                            Task {
                                if await model.add(place) { onDone() }
                            }
                        } label: {
                            PlaceRow(name: place.name, detail: place.region, systemImage: "plus.circle")
                        }
                        .buttonStyle(SoftPress())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                if query.isEmpty {
                    Section {
                        if model.usesLocation {
                            PlaceRow(name: "Current location", detail: model.forecasts[ForecastCache.here]?.name, systemImage: "location.fill")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions {
                                    Button("Stop using location") { model.stopUsingLocation() }
                                }
                        } else if model.locationAccess != .denied {
                            Button {
                                Task { await model.useMyLocation() }
                            } label: {
                                PlaceRow(name: "Use my location", detail: "Asked only while you use the app", systemImage: "location")
                            }
                            .buttonStyle(SoftPress())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        ForEach(model.places) { place in
                            Button {
                                model.selected = place.id.uuidString
                                onDone()
                            } label: {
                                PlaceRow(name: place.name, detail: summary(place), systemImage: nil)
                            }
                            .buttonStyle(SoftPress())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onMove { from, to in Task { await model.move(fromOffsets: from, toOffset: to) } }
                        .onDelete { offsets in
                            let ids = offsets.map { model.places[$0].id }
                            Task { for id in ids { await model.remove(id) } }
                        }
                        // A plain last row, not a Section footer: a footer gets the system's own band.
                        Text("Your places are end-to-end encrypted and follow you to your other devices.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg.color)
            .navigationTitle("Places")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
            .task(id: query) { await search() }
        }
    }

    private func summary(_ place: WeatherPlace) -> String {
        guard let cached = model.forecasts[place.id.uuidString] else { return place.region }
        return "\(model.units.temp(cached.forecast.now.temperature)) \(cached.forecast.now.condition.name)"
    }

    private func search() async {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard words.count >= 2 else {
            found = []
            searchProblem = nil
            return
        }
        // Wait for a pause in typing, so each letter isn't sent.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            found = try await model.search(words)
            searchProblem = found.isEmpty ? "No city by that name." : nil
        } catch WeatherError.offline {
            searchProblem = "You're offline, so cities can't be searched."
        } catch {
            guard !Task.isCancelled else { return }
            searchProblem = "The city search didn't answer. Try again in a minute."
        }
    }
}

/// One place in a list: its name, a quiet line and an icon.
struct PlaceRow: View {
    let name: String
    let detail: String?
    let systemImage: String?

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent.color)
                    .frame(width: Space.s5)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Typeface.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary.color)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            Spacer(minLength: 0)
        }
        .itemCard()
        .accessibilityElement(children: .combine)
    }
}

/// Units and alerts, kept on this iPhone.
struct WeatherSettingsSheet: View {
    @Bindable var model: WeatherModel
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Temperature")
                            .font(Typeface.tileLabel)
                            .foregroundStyle(theme.textSecondary.color)
                        FilterPills(WeatherUnits.Temperature.allCases, selection: $model.units.temperature) { $0.symbol }
                        Text("Wind")
                            .font(Typeface.tileLabel)
                            .foregroundStyle(theme.textSecondary.color)
                        FilterPills(WeatherUnits.Speed.allCases, selection: $model.units.speed) { $0.symbol }
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Toggle("Severe weather alerts", isOn: Binding(get: { model.alertsOn }, set: { on in Task { await model.setAlerts(on) } }))
                            .font(Typeface.body)
                            .tint(theme.accent.color)
                            .raisedField()
                        Text("When Weather refreshes on this iPhone and finds a new severe or extreme alert for one of your places, it lets you know. It's made on the iPhone, so no server learns your places. Alerts come from the National Weather Service, in the US only.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Text("Units start from your region and stay on this iPhone.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("Weather settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}

/// One day's hours, opened from the ten days.
struct DaySheet: View {
    let day: Forecast.Day
    let forecast: Forecast
    let place: String
    let units: WeatherUnits
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        let zone = forecast.zone
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: Space.s3) {
                        Image(systemName: day.condition.systemImage())
                            .font(Typeface.title)
                            .foregroundStyle(theme.accent.color)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(day.condition.name)
                                .font(Typeface.headline)
                                .foregroundStyle(theme.textPrimary.color)
                            Text("H \(units.temp(day.high))  L \(units.temp(day.low))\(day.chance >= 10 ? " · \(Int(day.chance.rounded()))% chance of rain or snow" : "")")
                                .font(Typeface.caption)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    let hours = forecast.hours(on: day)
                    if hours.isEmpty {
                        Text("Hour by hour isn't known this far ahead.")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    } else {
                        ForecastCard("Hour by hour") {
                            ForEach(hours) { hour in
                                HStack(spacing: Space.s3) {
                                    Text(WeatherClock.hour(hour.time, in: zone))
                                        .font(Typeface.callout)
                                        .foregroundStyle(theme.textSecondary.color)
                                        .frame(width: Space.s7, alignment: .leading)
                                    Image(systemName: hour.condition.systemImage(isDaylight: hour.isDaylight))
                                        .foregroundStyle(hour.condition.isWet ? theme.accent.color : theme.textSecondary.color)
                                        .frame(width: Space.s5)
                                    Text(hour.condition.name)
                                        .font(Typeface.callout)
                                        .foregroundStyle(theme.textPrimary.color)
                                    Spacer(minLength: 0)
                                    if hour.chance >= 10 {
                                        Text("\(Int(hour.chance.rounded()))%")
                                            .font(Typeface.micro)
                                            .monospacedDigit()
                                            .foregroundStyle(theme.accent.color)
                                    }
                                    Text(units.temp(hour.temperature))
                                        .font(Typeface.callout.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.textPrimary.color)
                                        .frame(width: Space.s6, alignment: .trailing)
                                }
                                .frame(minHeight: Space.s6 + Space.s1)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    HStack(spacing: Space.s3) {
                        if let sunrise = day.sunrise { DetailCard("Sunrise", WeatherClock.time(sunrise, in: zone)) }
                        if let sunset = day.sunset { DetailCard("Sunset", WeatherClock.time(sunset, in: zone)) }
                        if let uv = day.uvMax { DetailCard("UV index", "\(Int(uv.rounded()))", detail: WeatherHomeView.uvWords(uv)) }
                    }
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color)
            .navigationTitle("\(place), \(WeatherClock.longDay(day.date, in: zone))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}

/// A severe weather alert in full, as the national service wrote it.
struct AlertSheet: View {
    let alert: WeatherAlert
    let onDone: () -> Void

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Text(alert.headline)
                        .font(Typeface.headline)
                        .foregroundStyle(theme.danger.color)
                    if let ends = alert.ends {
                        Text("Until \(ends.formatted(date: .abbreviated, time: .shortened))")
                            .font(Typeface.caption)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Text(alert.details)
                        .font(Typeface.body)
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                    Text("From \(alert.issuer)")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.bg.color)
            .navigationTitle(alert.event)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}

/// The places on a map, each with its temperature. Apple's map is free in the app. There's no radar layer:
/// RainViewer's free radar is for personal and educational use only, so it waits for the owner (issue 203).
struct PlacesMapSheet: View {
    @Bindable var model: WeatherModel
    let onDone: () -> Void

    struct Pin: Identifiable {
        let key: String
        let name: String
        let coordinate: Coordinate
        let label: String
        var id: String { key }
    }

    private var pins: [Pin] {
        var pins: [Pin] = []
        if model.usesLocation, let here = model.here {
            pins.append(Pin(key: ForecastCache.here, name: model.forecasts[ForecastCache.here]?.name ?? "You", coordinate: here, label: label(ForecastCache.here)))
        }
        pins += model.places.map { Pin(key: $0.id.uuidString, name: $0.name, coordinate: $0.coordinate, label: label($0.id.uuidString)) }
        return pins
    }

    private func label(_ key: String) -> String {
        model.forecasts[key].map { model.units.temp($0.forecast.now.temperature) } ?? "–"
    }

    var body: some View {
        let theme = Theme.current
        NavigationStack {
            Group {
                #if canImport(MapKit)
                Map {
                    ForEach(pins) { pin in
                        Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)) {
                            Button {
                                model.selected = pin.key
                                onDone()
                            } label: {
                                Text(pin.label)
                                    .font(Typeface.callout.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.textPrimary.color)
                                    .padding(.horizontal, Space.s3)
                                    .padding(.vertical, Space.s2)
                                    .neumorphic(.raised, in: Capsule())
                            }
                            .buttonStyle(SoftPress())
                            .accessibilityLabel("\(pin.name), \(pin.label)")
                        }
                    }
                }
                #else
                Text("The map isn't available here.")
                #endif
            }
            .navigationTitle("Map")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}
