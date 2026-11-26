import Foundation

/// Whether Hiking may read where the person is.
public enum HikeLocationAccess: Equatable, Sendable {
    case notAsked, allowed, denied
}

/// Where the person is, read on the iPhone "While Using the App" only, never Always (issue 240, section 3).
/// What it reads stays on the iPhone: only Nearby's rough location, rounded to about 1 km, is ever sent.
@MainActor
public protocol HikeLocating: AnyObject {
    var access: HikeLocationAccess { get }
    /// Asks if not asked yet, then reads where the person is, or nil.
    func currentLocation() async -> GeoPoint?
    /// Starts reporting each fix, with its accuracy in metres, until `stop`. It carries on with the screen
    /// locked while a hike is being recorded.
    func start(_ onFix: @escaping @MainActor (GeoPoint, Double, Date) -> Void)
    func stop()
}

#if canImport(CoreLocation)
import CoreLocation

@MainActor
public final class SystemHikeLocation: NSObject, HikeLocating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waitingForAccess: [CheckedContinuation<Void, Never>] = []
    private var waitingForLocation: [CheckedContinuation<CLLocation?, Never>] = []
    private var onFix: (@MainActor (GeoPoint, Double, Date) -> Void)?
    #if os(iOS)
    /// Lets recording carry on with the screen locked, with "While Using" access only. iOS shows the
    /// location pill while it's held.
    private var background: CLBackgroundActivitySession?
    #endif

    public override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
    }

    public var access: HikeLocationAccess {
        switch manager.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        default: .allowed
        }
    }

    private func askIfNeeded() async {
        guard access == .notAsked else { return }
        await withCheckedContinuation { continuation in
            waitingForAccess.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    public func currentLocation() async -> GeoPoint? {
        await askIfNeeded()
        guard access == .allowed else { return nil }
        if let last = manager.location, last.timestamp.timeIntervalSinceNow > -300 { return Self.point(last) }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let found = await withCheckedContinuation { continuation in
            waitingForLocation.append(continuation)
            if waitingForLocation.count == 1 { manager.requestLocation() }
        }
        return found.map(Self.point)
    }

    public func start(_ onFix: @escaping @MainActor (GeoPoint, Double, Date) -> Void) {
        self.onFix = onFix
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = TrackBuilder.spacing
        #if os(iOS)
        if Self.mayRunInBackground {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            background = CLBackgroundActivitySession()
        }
        manager.pausesLocationUpdatesAutomatically = false
        #endif
        Task {
            await askIfNeeded()
            guard access == .allowed else { return }
            manager.startUpdatingLocation()
        }
    }

    public func stop() {
        onFix = nil
        manager.stopUpdatingLocation()
        #if os(iOS)
        background?.invalidate()
        background = nil
        if Self.mayRunInBackground { manager.allowsBackgroundLocationUpdates = false }
        #endif
    }

    /// Setting background updates without the `location` background mode would crash, so it's checked.
    private static var mayRunInBackground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    private static func point(_ location: CLLocation) -> GeoPoint {
        GeoPoint(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            elevation: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
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
        Task { @MainActor in
            if !waitingForLocation.isEmpty { finish(locations.last) }
            guard let onFix else { return }
            for location in locations {
                onFix(Self.point(location), location.horizontalAccuracy, location.timestamp)
            }
        }
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
