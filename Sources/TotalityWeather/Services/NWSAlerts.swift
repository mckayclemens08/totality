import Foundation

/// Severe weather alerts, from wherever they come.
public protocol AlertSource: Sendable {
    func alerts(at coordinate: Coordinate) async throws -> [WeatherAlert]
}

/// The US National Weather Service's active alerts: free, public domain, and no key (issue 203, section 3).
/// Only a point inside the United States is ever sent to it.
public struct NWSAlerts: AlertSource {
    public static let sourceName = "the National Weather Service"

    private let http: any WeatherHTTP

    public init(http: any WeatherHTTP = URLSessionWeatherHTTP()) {
        self.http = http
    }

    /// The service asks every client to name itself. This names the app, never the person.
    static let headers = ["User-Agent": "Totality-Weather", "Accept": "application/geo+json"]

    static func url(for coordinate: Coordinate) -> URL {
        var parts = URLComponents(string: "https://api.weather.gov/alerts/active")!
        parts.queryItems = [.init(name: "point", value: String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude))]
        return parts.url!
    }

    public func alerts(at coordinate: Coordinate) async throws -> [WeatherAlert] {
        let rough = coordinate.rough
        guard rough.isInUnitedStates else { return [] }
        return try Self.parse(try await http.get(Self.url(for: rough), headers: Self.headers))
    }

    struct Answer: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let id: String?
                let event: String?
                let headline: String?
                let severity: String?
                let ends: String?
                let expires: String?
                let description: String?
                let instruction: String?
                let senderName: String?
                let status: String?
            }
            let id: String?
            let properties: Properties
        }
        let features: [Feature]
    }

    static func parse(_ data: Data) throws -> [WeatherAlert] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw WeatherError.badAnswer }
        let dates = ISO8601DateFormatter()
        return answer.features.compactMap { feature in
            let p = feature.properties
            // Tests and drills aren't real warnings.
            guard let event = p.event, p.status == nil || p.status == "Actual",
                  let id = p.id ?? feature.id else { return nil }
            let details = [p.description, p.instruction].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            return WeatherAlert(
                id: id, event: event, headline: p.headline ?? event,
                severity: WeatherAlert.Severity(rawValue: (p.severity ?? "").lowercased()) ?? .unknown,
                ends: (p.ends ?? p.expires).flatMap { dates.date(from: $0) },
                details: details, issuer: p.senderName ?? "National Weather Service"
            )
        }
        .sorted { $0.severity > $1.severity }
    }
}
