import Foundation

/// A place someone keeps in one module that another can use, like a Clock city that Weather shows the
/// forecast for (issue 204). A name and a time zone, and a spot on the map when the module knows one. It
/// comes from private content, so it stays in memory on this device and is never stored or sent by the
/// module that asks.
public struct NamedPlace: Identifiable, Sendable, Hashable {
    /// Means something only to the module that gave it.
    public let id: String
    /// What the person sees, like "Phoenix".
    public let name: String
    /// An IANA time zone, like "America/Phoenix".
    public let timeZoneID: String
    public let latitude: Double?
    public let longitude: Double?
    /// The module it comes from.
    public let module: ModuleID

    public init(id: String, name: String, timeZoneID: String, latitude: Double? = nil, longitude: Double? = nil, module: ModuleID) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
        self.latitude = latitude
        self.longitude = longitude
        self.module = module
    }
}

/// A module that keeps places another module may want, like Clock's world cities. Others reach it only
/// through `ModuleRegistry.placesProviders`.
public protocol PlacesProvider: ContentHandler {
    /// The places kept, in the person's order.
    func places() async -> [NamedPlace]
}

extension ModuleRegistry {
    /// Every module that keeps places, in the order they were registered.
    public var placesProviders: [any PlacesProvider] {
        handlers.compactMap { $0 as? any PlacesProvider }
    }

    /// Everything kept as a place, leaving out `module`'s own.
    public func places(except module: ModuleID) async -> [NamedPlace] {
        var places: [NamedPlace] = []
        for provider in placesProviders where provider.module != module { places += await provider.places() }
        return places
    }
}
