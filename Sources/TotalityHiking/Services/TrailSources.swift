import Foundation

/// Fetches from the network, so tests can answer instead.
public protocol HikingHTTP: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
    /// A form POST (`application/x-www-form-urlencoded`), with its own time limit in seconds.
    func post(_ url: URL, form: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data
}

/// The real network, with nothing kept: no cookies, no cache and no stored credentials.
public struct URLSessionHikingHTTP: HikingHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request)
    }

    public func post(_ url: URL, form: [String: String], headers: [String: String], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(HikingForm.encode(form).utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            throw HikingError.offline
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw HikingError.failed }
        return data
    }
}

/// Form encoding with every reserved character escaped, so a query's brackets, pipes, plus signs and ampersands survive.
enum HikingForm {
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

/// Names Totality to the community servers, as their policies ask, with no detail about the person.
let userAgent = "Totality-Hiking/1.0 (+https://usetotality.com)"

/// Trails near a place, from OpenStreetMap through the public Overpass API (issue 240, section 2). Free,
/// under the ODbL, credited as "© OpenStreetMap contributors". Asked only when the person opens Nearby or
/// pulls to refresh, with the location rounded to about 1 km. Overpass sees that and the iPhone's IP address.
public struct OverpassTrails: Sendable {
    public static let credit = "Trails © OpenStreetMap contributors"
    public static let radius = 8000
    static let most = 40

    private let http: any HikingHTTP

    public init(http: any HikingHTTP = URLSessionHikingHTTP()) {
        self.http = http
    }

    static func query(around point: GeoPoint) -> String {
        let at = String(format: "%.2f,%.2f", point.latitude, point.longitude)
        return """
        [out:json][timeout:25];
        (
          relation["route"="hiking"]["name"](around:\(radius),\(at));
          way["highway"~"^(path|footway|bridleway|track)$"]["name"]["footway"!~"sidewalk|crossing"]["access"!~"private|no"](around:\(radius),\(at));
        );
        out tags geom 300;
        """
    }

    /// The public servers, tried in order. The first often says "at capacity" at busy hours.
    static let servers: [URL] = [
        "https://overpass-api.de/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ].map { URL(string: $0)! }

    /// Seconds to wait on each server before trying the next.
    static let wait: TimeInterval = 20

    public func trails(near here: GeoPoint) async throws -> [Trail] {
        let rough = here.rough
        guard rough.isValid else { throw HikingError.badAnswer }
        let form = ["data": Self.query(around: rough)]
        var last: Error = HikingError.failed
        for server in Self.servers {
            do {
                let data = try await http.post(server, form: form, headers: ["User-Agent": userAgent, "Accept": "application/json"], timeout: Self.wait)
                return try Self.parse(data, near: rough)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = error
            }
        }
        throw last
    }

    // MARK: Reading the answer

    private struct Answer: Decodable {
        let elements: [Element]
        /// Set when the server gave up part-way ("runtime error: ... timed out").
        let remark: String?
    }

    private struct Element: Decodable {
        let type: String
        let id: Int
        let tags: [String: String]?
        let geometry: [LatLon?]?
        let members: [Member]?
    }

    private struct Member: Decodable {
        let type: String
        let geometry: [LatLon?]?
    }

    private struct LatLon: Decodable {
        let lat: Double
        let lon: Double
    }

    private static func line(_ geometry: [LatLon?]?) -> [GeoPoint] {
        (geometry ?? []).compactMap { $0.map { GeoPoint(latitude: $0.lat, longitude: $0.lon) } }
    }

    /// Route relations become one trail each. Named ways that aren't already part of a route of the same
    /// name are joined by name, since a long path is often several ways. Short bits are left out.
    static func parse(_ data: Data, near here: GeoPoint) throws -> [Trail] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw HikingError.badAnswer }
        if answer.elements.isEmpty, answer.remark != nil { throw HikingError.badAnswer }
        var trails: [Trail] = []
        var routeNames = Set<String>()
        for element in answer.elements where element.type == "relation" {
            guard let name = element.tags?["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let lines = (element.members ?? []).filter { $0.type == "way" }.map { line($0.geometry) }.filter { $0.count > 1 }
            guard !lines.isEmpty else { continue }
            routeNames.insert(name.lowercased())
            trails.append(Trail(
                id: "relation/\(element.id)", name: name, lines: lines, sacScale: element.tags?["sac_scale"],
                surface: element.tags?["surface"], kind: "Hiking route"
            ))
        }
        var byName: [String: Trail] = [:]
        var order: [String] = []
        for element in answer.elements where element.type == "way" {
            guard let tags = element.tags, let name = tags["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !routeNames.contains(key) else { continue }
            let points = line(element.geometry)
            guard points.count > 1 else { continue }
            if var trail = byName[key] {
                trail.lines.append(points)
                if trail.sacScale == nil { trail.sacScale = tags["sac_scale"] }
                if trail.surface == nil { trail.surface = tags["surface"] }
                byName[key] = trail
            } else {
                order.append(key)
                byName[key] = Trail(
                    id: "way/\(element.id)", name: name, lines: [points], sacScale: tags["sac_scale"],
                    surface: tags["surface"], kind: (tags["highway"] ?? "path").capitalized
                )
            }
        }
        trails += order.compactMap { byName[$0] }
        return trails
            .filter { $0.metres >= 300 }
            .sorted { $0.distance(from: here) < $1.distance(from: here) }
            .prefix(most)
            .map { $0 }
    }
}

/// Heights along a trail from Open-Meteo's elevation API, on the Copernicus GLO-90 model (issue 240,
/// section 2). Free for non-commercial use, credited to Copernicus and Open-Meteo. Only the trail's own
/// points are sent, at most 100, never where the person is.
public struct OpenMeteoElevation: Sendable {
    public static let credit = "Elevation: Copernicus GLO-90 via Open-Meteo"
    static let most = 100

    private let http: any HikingHTTP

    public init(http: any HikingHTTP = URLSessionHikingHTTP()) {
        self.http = http
    }

    static func url(for points: [GeoPoint]) -> URL {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        parts.queryItems = [
            .init(name: "latitude", value: points.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: points.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")),
        ]
        return parts.url!
    }

    /// The heights at up to 100 points spread along the trail, start to end.
    public func profile(of trail: Trail) async throws -> [Double] {
        let points = GeoLine.sampled(trail.points, count: Self.most)
        guard points.count > 1 else { throw HikingError.badAnswer }
        let data = try await http.get(Self.url(for: points), headers: ["User-Agent": userAgent])
        return try Self.parse(data, count: points.count)
    }

    private struct Answer: Decodable {
        let elevation: [Double]
    }

    static func parse(_ data: Data, count: Int) throws -> [Double] {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.elevation.count == count else {
            throw HikingError.badAnswer
        }
        return answer.elevation
    }
}
