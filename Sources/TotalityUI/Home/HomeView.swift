import SwiftUI
import TotalityCore

/// The home page: a dashboard of tiles, or the flower for anyone who prefers it. The arrangement is
/// saved on this device.
public struct HomeView: View {
    private let modules: [ModuleEntry]
    private let center: ModuleID
    private let glances: [ModuleID: ModuleGlance]
    @Binding private var style: HomeStyle
    private let onOpen: (ModuleID) -> Void
    private let onSearch: () -> Void
    // Module names and sizes, never content.
    @AppStorage("home.layout") private var savedLayout = Data()
    @State private var isEditing = false

    private static let topBarHeight = Space.s4 + Space.s7

    public init(
        modules: [ModuleEntry] = ModuleEntry.all,
        center: ModuleID = .reader,
        glances: [ModuleID: ModuleGlance] = [:],
        style: Binding<HomeStyle> = .constant(.tiles),
        onOpen: @escaping (ModuleID) -> Void,
        onSearch: @escaping () -> Void = {}
    ) {
        self.modules = modules
        self.center = center
        self.glances = glances
        _style = style
        self.onOpen = onOpen
        self.onSearch = onSearch
    }

    private var layout: Binding<HomeLayout> {
        Binding {
            HomeLayout(saved: savedLayout, modules: modules.map(\.id))
        } set: {
            savedLayout = $0.saved
        }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.current.bg.color.ignoresSafeArea()
            switch style {
            case .tiles:
                GeometryReader { proxy in
                    ScrollView {
                        BentoGrid(
                            layout: layout, modules: modules, glances: glances,
                            width: min(proxy.size.width - Space.s4 * 2, Space.s8 * 8),
                            isEditing: $isEditing, onOpen: onOpen
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Self.topBarHeight + Space.s4)
                        .padding(.bottom, Space.s6)
                    }
                }
            case .flower:
                FlowerView(modules: ModuleEntry.arranged(modules, around: center), onOpen: onOpen)
            }
            topBar
        }
    }

    /// Floats over the page, so tiles fade out under it instead of stopping at a hard edge.
    private var topBar: some View {
        let background = Theme.current.bg.color
        return HStack(spacing: Space.s3) {
            Spacer()
            if isEditing {
                Button("Done") { isEditing = false }
                    .font(Typeface.callout)
                    .foregroundStyle(Theme.current.accent.color)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.s4)
                    .frame(height: Space.s7)
                    .neumorphic(.subtle, in: Capsule())
            } else {
                Button(action: onSearch) {
                    TopBarIcon(systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                Button {
                    style = style == .tiles ? .flower : .tiles
                } label: {
                    TopBarIcon(systemImage: style == .tiles ? "circle.hexagongrid" : "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style == .tiles ? "Show flower" : "Show tiles")
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .background {
            LinearGradient(colors: [background, background.opacity(0)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

private struct TopBarIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(Typeface.body)
            .foregroundStyle(Theme.current.textPrimary.color)
            .frame(width: Space.s7, height: Space.s7)
            .neumorphic(.subtle, in: Circle())
    }
}

struct FlowerView: View {
    /// The first module is the centre.
    let modules: [ModuleEntry]
    let onOpen: (ModuleID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = FlowerLayout(ringCount: max(modules.count - 1, 0), in: proxy.size)
            ZStack {
                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    let point = layout.position(at: index)
                    Button {
                        onOpen(module.id)
                    } label: {
                        BubbleLabel(module: module, diameter: layout.diameter)
                    }
                    .buttonStyle(BubbleButtonStyle())
                    .position(x: proxy.size.width / 2 + point.x, y: proxy.size.height / 2 + point.y)
                }
            }
            .animation(reduceMotion ? nil : Motion.standard, value: modules)
        }
    }
}

private struct BubbleLabel: View {
    let module: ModuleEntry
    let diameter: CGFloat
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 26

    var body: some View {
        Image(systemName: module.systemImage)
            .font(.system(size: min(iconSize, diameter / 2), weight: .regular))
            .foregroundStyle(Theme.current.textPrimary.color)
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(module.name)
    }
}

private struct BubbleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .neumorphic(configuration.isPressed ? .pressed : .raised, in: Circle())
            .contentShape(Circle())
            .animation(Motion.instant, value: configuration.isPressed)
    }
}
