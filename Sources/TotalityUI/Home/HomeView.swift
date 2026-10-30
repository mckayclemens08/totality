import SwiftUI
import TotalityCore

/// The launcher: the most recently used module in the centre, with the others in a ring around it.
/// The list holds the same modules for anyone who finds it faster.
public struct HomeView: View {
    private let modules: [ModuleEntry]
    private let center: ModuleID
    private let onOpen: (ModuleID) -> Void
    @State private var showsList = false
    @Environment(\.colorScheme) private var scheme

    public init(modules: [ModuleEntry] = ModuleEntry.all, center: ModuleID = .reader, onOpen: @escaping (ModuleID) -> Void) {
        self.modules = modules
        self.center = center
        self.onOpen = onOpen
    }

    public var body: some View {
        let arranged = ModuleEntry.arranged(modules, around: center)
        ZStack(alignment: .topTrailing) {
            Theme.current(scheme).bg.color.ignoresSafeArea()
            if showsList {
                ModuleListView(modules: arranged, onOpen: onOpen)
            } else {
                FlowerView(modules: arranged, onOpen: onOpen)
            }
            Button {
                showsList.toggle()
            } label: {
                Image(systemName: showsList ? "circle.hexagongrid" : "list.bullet")
                    .font(Typeface.body)
                    .foregroundStyle(Theme.current(scheme).textPrimary.color)
                    .frame(width: Space.s7, height: Space.s7)
                    .neumorphic(.subtle, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Space.s4)
            .accessibilityLabel(showsList ? "Show ring" : "Show list")
        }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: module.systemImage)
            .font(.system(size: min(iconSize, diameter / 2), weight: .regular))
            .foregroundStyle(Theme.current(scheme).textPrimary.color)
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
