import SwiftUI
import TotalityCore

// A module opens by zooming out of its tile on Home, and closes by shrinking back into it (iOS 18 and
// later). Earlier systems slide the module up as a cover instead.

private struct HomeZoom: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Where Home's tiles register as the source of a module's zoom. Nil draws plain tiles.
    public var homeZoom: Namespace.ID? {
        get { self[HomeZoom.self] }
        set { self[HomeZoom.self] = newValue }
    }
}

extension View {
    /// Makes this module's screen zoom out of its tile on Home.
    @ViewBuilder
    public func zoomsFromHomeTile(_ module: ModuleID, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: module, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Marks a tile as where its module zooms from.
    func homeZoomSource(_ module: ModuleID) -> some View {
        modifier(HomeZoomSource(module: module))
    }
}

private struct HomeZoomSource: ViewModifier {
    let module: ModuleID
    @Environment(\.homeZoom) private var namespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18, *), let namespace {
            content.matchedTransitionSource(id: module, in: namespace) { source in
                source
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .background(Theme.current.surface.color)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
