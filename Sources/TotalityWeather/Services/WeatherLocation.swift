import Foundation

/// Whether Weather may read where the person is.
public enum LocationAccess: Equatable, Sendable {
    /// Not asked yet.
    case notAsked
    case allowed
    /// Turned off for Totality, or not allowed on this iPhone. The place list still works.
    case denied
}

/// Where the person is, read on the iPhone "While Using the App" only, never Always, and rounded to about
/// 1 km at once. It's never saved or sent to Totality's server (issue 203, section 4).
@MainActor
public protocol WeatherLocating: AnyObject {
    var access: LocationAccess { get }
    /// Asks if not asked yet, then reads the rough location, or nil if it isn't allowed or can't be found.
    func roughLocation() async -> Coordinate?
    /// A short name for a rough location, such as "Provo", or nil.
    func name(of coordinate: Coordinate) async -> String?
}

#if canImport(CoreLocation)
import CoreLocation

@MainActor
public final class SystemWeatherLocation: NSObject, WeatherLocating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waitingForAccess: [CheckedContinuation<Void, Never>] = []
    private var waitingForLocation: [CheckedContinuation<CLLocation?, Never>] = []

    public override init() {
        super.init()
        manager.delegate = self
        // A kilometre is all a forecast needs, and it costs the battery least.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public var access: LocationAccess {
        switch manager.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        default: .allowed
        }
    }

    public func roughLocation() async -> Coordinate? {
        if access == .notAsked {
            await withCheckedContinuation { continuation in
                waitingForAccess.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        guard access == .allowed else { return nil }
        // A recent one will do, without waking the radios.
        if let last = manager.location, last.timestamp.timeIntervalSinceNow > -600 {
            return Self.rough(last)
        }
        let found = await withCheckedContinuation { continuation in
            waitingForLocation.append(continuation)
            if waitingForLocation.count == 1 { manager.requestLocation() }
        }
        return found.map(Self.rough)
    }

    public func name(of coordinate: Coordinate) async -> String? {
        let place = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
        return place?.locality ?? place?.subAdministrativeArea ?? place?.administrativeArea
    }

    private static func rough(_ location: CLLocation) -> Coordinate {
        Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude).rough
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiting = waitingForAccess
            waitingForAccess = []
            waiting.forEach { $0.resume() }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in finish(last) }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in finish(nil) }
    }

    private func finish(_ location: CLLocation?) {
        let waiting = waitingForLocation
        waitingForLocation = []
        waiting.forEach { $0.resume(returning: location) }
    }
}
#endif
