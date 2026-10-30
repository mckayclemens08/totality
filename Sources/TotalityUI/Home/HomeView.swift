import SwiftUI
import TotalityCore

/// The launcher. The bubble cloud is the default, and the list holds the same modules for anyone
/// who finds it faster. Reduce Motion starts on the list, because panning is the cloud's main motion.
public struct HomeView: View {
    private let modules: [ModuleEntry]
    private let onOpen: (ModuleID) -> Void
    @State private var showsList: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    public init(modules: [ModuleEntry] = ModuleEntry.all, onOpen: @escaping (ModuleID) -> Void) {
        self.modules = modules
        self.onOpen = onOpen
    }

    private var listIsShown: Bool {
        showsList ?? reduceMotion
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.current(scheme).bg.color.ignoresSafeArea()
            if listIsShown {
                ModuleListView(modules: modules, onOpen: onOpen)
            } else {
                BubbleCloudView(modules: modules, onOpen: onOpen)
            }
            Button {
                showsList = !listIsShown
            } label: {
                Image(systemName: listIsShown ? "circle.hexagongrid" : "list.bullet")
                    .font(Typeface.body)
                    .foregroundStyle(Theme.current(scheme).textPrimary.color)
                    .frame(width: 44, height: 44)
                    .neumorphic(.subtle, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Space.s4)
            .accessibilityLabel(listIsShown ? "Show bubbles" : "Show list")
        }
    }
}

struct BubbleCloudView: View {
    let modules: [ModuleEntry]
    let onOpen: (ModuleID) -> Void
    private let layout = BubbleLayout()
    @State private var offset = CGSize.zero
    @State private var settled = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    let home = layout.position(at: index)
                    let point = CGPoint(x: home.x + offset.width, y: home.y + offset.height)
                    let scale = layout.scale(at: point, in: proxy.size)
                    Button {
                        onOpen(module.id)
                    } label: {
                        BubbleLabel(module: module)
                    }
                    .buttonStyle(BubbleButtonStyle())
                    .scaleEffect(scale)
                    .position(x: proxy.size.width / 2 + point.x, y: proxy.size.height / 2 + point.y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        offset = layout.clampedOffset(
                            CGSize(
                                width: settled.width + value.translation.width,
                                height: settled.height + value.translation.height
                            ),
                            count: modules.count
                        )
                    }
                    .onEnded { _ in
                        settled = offset
                    }
            )
        }
        .clipped()
    }
}

private struct BubbleLabel: View {
    let module: ModuleEntry
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: module.systemImage)
            .font(.system(size: iconSize, weight: .regular))
            .foregroundStyle(Theme.current(scheme).textPrimary.color)
            .frame(width: BubbleLayout.bubbleDiameter, height: BubbleLayout.bubbleDiameter)
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

struct ModuleListView: View {
    let modules: [ModuleEntry]
    let onOpen: (ModuleID) -> Void

    var body: some View {
        ScrollView {
            ModuleRows(modules: modules, onOpen: onOpen)
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s8)
                .padding(.bottom, Space.s4)
        }
    }
}

struct ModuleRows: View {
    let modules: [ModuleEntry]
    let onOpen: (ModuleID) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme.current(scheme)
        LazyVStack(spacing: Space.s3) {
            ForEach(modules) { module in
                Button {
                    onOpen(module.id)
                } label: {
                    HStack(spacing: Space.s3) {
                        Image(systemName: module.systemImage)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        Text(module.name)
                            .font(Typeface.headline)
                        Spacer()
                    }
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(Space.s4)
                    .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
