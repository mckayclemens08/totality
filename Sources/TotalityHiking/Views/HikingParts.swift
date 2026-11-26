import MapKit
import SwiftUI
import TotalityCore
import TotalityUI

/// Easy, Moderate or Hard, as a small coloured pill.
struct DifficultyBadge: View {
    let difficulty: Difficulty
    var short = false

    var body: some View {
        let colour = tone.color
        Text(short && difficulty == .moderate ? "MOD" : difficulty.name.uppercased())
            .font(Typeface.micro)
            .tracking(0.4)
            .foregroundStyle(colour)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1 / 2)
            .background(Capsule().fill(colour.opacity(0.14)))
            .accessibilityLabel("Difficulty: \(difficulty.name)")
    }

    private var tone: ColorToken {
        let theme = Theme.current
        switch difficulty {
        case .easy: return theme.success
        case .moderate: return theme.accent
        case .hard: return theme.danger
        }
    }
}

/// One figure with its label under it, like "3.9 km / DISTANCE".
struct StatBox: View {
    let value: String
    let label: String

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Typeface.headline)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(Typeface.micro)
                .tracking(0.4)
                .foregroundStyle(theme.textSecondary.color)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A card with an optional small heading, raised like Weather's.
struct HikingCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s2) {
            if let title {
                Text(title)
                    .font(Typeface.tileLabel)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// The route on an Apple map. The line is drawn from points kept on the iPhone, so a saved trail shows it
/// with no signal; the map behind it is whatever MapKit has cached.
struct RouteMap: View {
    let lines: [[GeoPoint]]
    var here: GeoPoint?
    var followsHere = false

    var body: some View {
        let theme = Theme.current
        Map(initialPosition: position) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line.map(\.coordinate))
                    .stroke(theme.accent.color, style: StrokeStyle(lineWidth: Space.s1, lineCap: .round, lineJoin: .round))
            }
            if let start = lines.first?.first {
                Annotation("Start", coordinate: start.coordinate) {
                    Circle().fill(theme.success.color).frame(width: Space.s3, height: Space.s3)
                }
            }
            if let here {
                Annotation("You", coordinate: here.coordinate) {
                    Circle().fill(theme.accent.color).frame(width: Space.s3, height: Space.s3)
                        .padding(Space.s1).background(Circle().fill(theme.accent.color.opacity(0.25)))
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityLabel("Map of the route")
    }

    private var position: MapCameraPosition {
        let points = lines.flatMap { $0 } + (here.map { [$0] } ?? [])
        if followsHere, let here { return .camera(MapCamera(centerCoordinate: here.coordinate, distance: 1500)) }
        guard let box = GeoLine.bounds(points) else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: (box.north + box.south) / 2, longitude: (box.east + box.west) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (box.north - box.south) * 1.4), longitudeDelta: max(0.005, (box.east - box.west) * 1.4))
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The line alone, drawn to fit, for a shared picture. No map, so it doesn't say where it is.
struct RouteDrawing: Shape {
    let lines: [[GeoPoint]]

    func path(in rect: CGRect) -> SwiftUI.Path {
        var path = SwiftUI.Path()
        guard let box = GeoLine.bounds(lines.flatMap { $0 }) else { return path }
        // Longitude shrinks towards the poles, so it's scaled to keep the shape true.
        let squeeze = cos((box.north + box.south) / 2 * .pi / 180)
        let width = max((box.east - box.west) * squeeze, 1e-6), height = max(box.north - box.south, 1e-6)
        let scale = min(rect.width / width, rect.height / height)
        let offsetX = rect.minX + (rect.width - width * scale) / 2, offsetY = rect.minY + (rect.height - height * scale) / 2
        for line in lines {
            for (index, point) in line.enumerated() {
                let spot = CGPoint(x: offsetX + (point.longitude - box.west) * squeeze * scale, y: offsetY + (box.north - point.latitude) * scale)
                if index == 0 { path.move(to: spot) } else { path.addLine(to: spot) }
            }
        }
        return path
    }
}

/// Heights along the route as a soft filled line, with the highest and lowest marked.
struct ElevationProfile: View {
    let heights: [Double]
    let units: HikeUnits

    var body: some View {
        let theme = Theme.current
        let low = heights.min() ?? 0, high = heights.max() ?? 1
        VStack(alignment: .leading, spacing: Space.s1) {
            GeometryReader { proxy in
                let size = proxy.size
                let span = max(high - low, 1)
                let points = heights.enumerated().map { index, height in
                    CGPoint(
                        x: heights.count > 1 ? size.width * CGFloat(index) / CGFloat(heights.count - 1) : 0,
                        y: size.height * (1 - CGFloat((height - low) / span)) * 0.9 + size.height * 0.05
                    )
                }
                ZStack {
                    SwiftUI.Path { path in
                        guard let first = points.first else { return }
                        path.move(to: CGPoint(x: first.x, y: size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(theme.highlight.color)
                    SwiftUI.Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(theme.accent.color, style: StrokeStyle(lineWidth: Space.hairline * 2, lineJoin: .round))
                }
            }
            .frame(height: Space.s8)
            HStack {
                Text("Low \(units.height(low))")
                Spacer()
                Text("High \(units.height(high))")
            }
            .font(Typeface.micro)
            .monospacedDigit()
            .foregroundStyle(theme.textSecondary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elevation from \(units.height(low)) to \(units.height(high))")
    }
}

/// The picture attached to a shared hike: the trimmed line and the figures, on the theme's surface.
struct ShareCard: View {
    let hike: Hike
    let units: HikeUnits

    var body: some View {
        let theme = Theme.current
        let route = HikingModel.sharedRoute(of: hike)
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(hike.title)
                .font(Typeface.title)
                .foregroundStyle(theme.textPrimary.color)
            if !route.isEmpty {
                RouteDrawing(lines: route)
                    .stroke(theme.accent.color, style: StrokeStyle(lineWidth: Space.s2, lineCap: .round, lineJoin: .round))
                    .frame(height: Space.s8 * 3)
                    .padding(Space.s2)
            }
            Text("\(units.distance(hike.metres)) · \(units.climb(hike.climb)) · \(HikeUnits.shortDuration(hike.seconds))")
                .font(Typeface.headline)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
        }
        .padding(Space.s5)
        .frame(width: Space.s8 * 6, alignment: .leading)
        .background(theme.surface.color)
    }

    /// The card as a JPEG, or nil where it can't be drawn.
    @MainActor
    static func jpeg(_ hike: Hike, units: HikeUnits) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(hike: hike, units: units))
        renderer.scale = 2
        #if canImport(UIKit)
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
        #else
        return nil
        #endif
    }
}

/// The empty, offline and failed states, quietly.
struct HikingMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            Image(systemName: systemImage)
                .font(Typeface.title)
                .foregroundStyle(theme.textSecondary.color)
            Text(title)
                .font(Typeface.headline)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typeface.caption)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity)
    }
}
