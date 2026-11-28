import SwiftUI
import TotalityCore

/// The home page: a dashboard of tiles. The arrangement is
/// saved on this device.
public struct HomeView: View {
    private let modules: [ModuleEntry]
    private let glances: [ModuleID: ModuleGlance]
    private let bigTile: (ModuleID, TileSize) -> AnyView?
    private let lineLink: (ModuleID, Int) -> (@MainActor () -> Void)?
    private let onOpen: (ModuleID) -> Void
    private let onSearch: () -> Void
    private let onAccount: (() -> Void)?
    /// Modules taken off Home. Their data stays, and links to them still open them.
    private let removed: Set<ModuleID>
    private let onRemove: (ModuleID) -> Void
    private let onRestore: (ModuleID) -> Void
    private let onLayoutChanged: ((Data) -> Void)?
    // Module names and sizes, never content.
    @AppStorage("home.layout") private var savedLayout = Data()
    @State private var isEditing = false
    @State private var adding = false

    private static let topBarHeight = Space.s4 + Metric.headerButton

    public init(
        modules: [ModuleEntry] = ModuleEntry.all,
        glances: [ModuleID: ModuleGlance] = [:],
        bigTile: @escaping (ModuleID, TileSize) -> AnyView? = { _, _ in nil },
        lineLink: @escaping (ModuleID, Int) -> (@MainActor () -> Void)? = { _, _ in nil },
        removed: Set<ModuleID> = [],
        onRemove: @escaping (ModuleID) -> Void = { _ in },
        onRestore: @escaping (ModuleID) -> Void = { _ in },
        onLayoutChanged: ((Data) -> Void)? = nil,
        onOpen: @escaping (ModuleID) -> Void,
        onSearch: @escaping () -> Void = {},
        onAccount: (() -> Void)? = nil
    ) {
        self.onAccount = onAccount
        self.removed = removed
        self.onRemove = onRemove
        self.onRestore = onRestore
        self.onLayoutChanged = onLayoutChanged
        self.modules = modules
        self.glances = glances
        self.bigTile = bigTile
        self.lineLink = lineLink
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
            topBar
        }
        // Entering and leaving edit mode, including from a hold on a tile.
        .motion(Motion.smooth, value: isEditing)
        .sheet(isPresented: $adding) {
            AddModulesView(modules: takenOff) { module in
                onRestore(module)
            } onDone: {
                adding = false
            }
        }
        .onChange(of: takenOff.isEmpty) { if takenOff.isEmpty { adding = false } }
        .onChange(of: isEditing) { wasEditing, editing in
            if wasEditing, !editing, !savedLayout.isEmpty { onLayoutChanged?(savedLayout) }
        }
        .onChange(of: savedLayout) { _, updated in
            if !isEditing, !updated.isEmpty { onLayoutChanged?(updated) }
        }
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
                HeaderPill("Done", isProminent: true) { withMotion(Motion.smooth) { isEditing = false } }
            } else {
                Spacer()
                HeaderButton("Search", systemImage: "magnifyingglass", action: onSearch)
                if let onAccount {
                    HeaderButton("Account", systemImage: "person.fill", action: onAccount)
                }
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s2)
        // Solid behind the buttons, so tiles scrolling up never show through them, then a short soft
        // fade instead of an edge.
        .background(alignment: .top) {
            VStack(spacing: 0) {
                background
                LinearGradient(colors: [background, background.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Space.s4)
            }
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
