import SwiftUI
import TotalityCore

/// The home page: a dashboard of tiles, or the flower for anyone who prefers it. The arrangement is
/// saved on this device.
public struct HomeView: View {
    private let modules: [ModuleEntry]
    private let center: ModuleID
    private let glances: [ModuleID: ModuleGlance]
    private let bigTile: (ModuleID, BigTileSize) -> AnyView?
    private let lineLink: (ModuleID, Int) -> (@MainActor () -> Void)?
    @Binding private var style: HomeStyle
    private let onOpen: (ModuleID) -> Void
    private let onSearch: () -> Void
    private let onAccount: (() -> Void)?
    /// Modules taken off Home. Their data stays, and links to them still open them.
    private let removed: Set<ModuleID>
    private let onRemove: (ModuleID) -> Void
    private let onRestore: (ModuleID) -> Void
    // Module names and sizes, never content.
    @AppStorage("home.layout") private var savedLayout = Data()
    @State private var isEditing = false
    @State private var adding = false

    private static let topBarHeight = Space.s4 + Metric.headerButton

    public init(
        modules: [ModuleEntry] = ModuleEntry.all,
        center: ModuleID = .reader,
        glances: [ModuleID: ModuleGlance] = [:],
        bigTile: @escaping (ModuleID, BigTileSize) -> AnyView? = { _, _ in nil },
        lineLink: @escaping (ModuleID, Int) -> (@MainActor () -> Void)? = { _, _ in nil },
        style: Binding<HomeStyle> = .constant(.tiles),
        removed: Set<ModuleID> = [],
        onRemove: @escaping (ModuleID) -> Void = { _ in },
        onRestore: @escaping (ModuleID) -> Void = { _ in },
        onOpen: @escaping (ModuleID) -> Void,
        onSearch: @escaping () -> Void = {},
        onAccount: (() -> Void)? = nil
    ) {
        self.onAccount = onAccount
        self.removed = removed
        self.onRemove = onRemove
        self.onRestore = onRestore
        self.modules = modules
        self.center = center
        self.glances = glances
        self.bigTile = bigTile
        self.lineLink = lineLink
        _style = style
        self.onOpen = onOpen
        self.onSearch = onSearch
    }

    private var layout: Binding<HomeLayout> {
        Binding { [removed] in
            var layout = HomeLayout(saved: savedLayout, modules: modules.map(\.id))
            layout.hidden = removed
            return layout
        } set: {
            savedLayout = $0.saved
        }
    }

    private var shown: [ModuleEntry] {
        modules.filter { !removed.contains($0.id) }
    }

    private var takenOff: [ModuleEntry] {
        modules.filter { removed.contains($0.id) }
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.current.bg.color.ignoresSafeArea()
            switch style {
            case .tiles:
                GeometryReader { proxy in
                    let width = min(proxy.size.width - Space.s4 * 2, Space.s8 * 8)
                    ScrollView {
                        VStack(spacing: Space.s4) {
                            heading
                                .frame(width: width)
                            if shown.isEmpty {
                                EmptyHome(width: width) { adding = true }
                            } else {
                                BentoGrid(
                                    layout: layout, modules: shown, glances: glances, bigTile: bigTile, lineLink: lineLink,
                                    width: width, isEditing: $isEditing, onOpen: onOpen, onRemove: onRemove
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, Self.topBarHeight + Space.s4)
                        .padding(.bottom, Space.s6)
                    }
                }
            case .flower:
                FlowerView(modules: ModuleEntry.arranged(shown, around: center), onOpen: onOpen)
            }
            topBar
        }
        .sheet(isPresented: $adding) {
            AddModulesView(modules: takenOff) { module in
                onRestore(module)
            } onDone: {
                adding = false
            }
        }
        .onChange(of: takenOff.isEmpty) { if takenOff.isEmpty { adding = false } }
    }

    /// Today's date and a greeting, or while editing, how editing works.
    @ViewBuilder
    private var heading: some View {
        if isEditing {
            Text("Drag to move. Tap a tile to change its size.")
                .font(Typeface.caption)
                .foregroundStyle(Theme.current.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s1)
        } else {
            TimelineView(.everyMinute) { context in
                ScreenTitle(HomeGreeting.title(at: context.date), subtitle: HomeGreeting.date(context.date))
                    .padding(.horizontal, Space.s1)
            }
        }
    }

    /// Floats over the page, so tiles fade out under it instead of stopping at a hard edge.
    private var topBar: some View {
        let background = Theme.current.bg.color
        return HStack(spacing: Space.s3) {
            if isEditing {
                HeaderPill("Add a tile", systemImage: "plus") { adding = true }
                Spacer()
                HeaderPill("Done", isProminent: true) { isEditing = false }
            } else {
                HeaderButton(
                    style == .tiles ? "Show flower" : "Show tiles",
                    systemImage: style == .tiles ? "circle.hexagongrid.fill" : "square.grid.2x2.fill"
                ) {
                    style = style == .tiles ? .flower : .tiles
                }
                Spacer()
                HeaderButton("Search", systemImage: "magnifyingglass", action: onSearch)
                if let onAccount {
                    HeaderButton("Account", systemImage: "person.fill", action: onAccount)
                }
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

/// The words at the top of Home.
enum HomeGreeting {
    static func title(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
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
            .neumorphic(.raised, in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? TilePress.scale : 1)
            .opacity(configuration.isPressed ? TilePress.opacity : 1)
            .animation(Motion.instant, value: configuration.isPressed)
    }
}
