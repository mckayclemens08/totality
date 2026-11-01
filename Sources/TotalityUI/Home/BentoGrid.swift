import SwiftUI
import TotalityCore

/// The home page's tiles. A tap opens a module. Holding any tile enters edit mode and picks it up, so
/// the same press can carry on into a drag.
struct BentoGrid: View {
    @Binding var layout: HomeLayout
    let modules: [ModuleEntry]
    let glances: [ModuleID: ModuleGlance]
    let width: CGFloat
    @Binding var isEditing: Bool
    let onOpen: (ModuleID) -> Void
    @State private var drag: TileDrag?
    @State private var holds = 0
    #if os(macOS)
    @State private var isHolding = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "bento"

    var body: some View {
        let metrics = BentoMetrics(width: width)
        let placements = layout.placements
        ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
                if let module = modules.first(where: { $0.id == placement.id }) {
                    tile(module, at: metrics.frame(of: placement), metrics: metrics)
                }
            }
        }
        .frame(width: width, height: metrics.height(of: placements), alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .animation(reduceMotion ? nil : Motion.standard, value: layout)
        .sensoryFeedback(.selection, trigger: holds)
        #if os(iOS)
        .background { TileHoldWatcher { held($0, metrics: metrics) } }
        #endif
    }

    private func tile(_ module: ModuleEntry, at frame: CGRect, metrics: BentoMetrics) -> some View {
        let dragged = drag?.id == module.id ? drag : nil
        return Button {
            if !isEditing { onOpen(module.id) }
        } label: {
            TileLabel(module: module, glance: glances[module.id], isHero: layout.hero == module.id)
        }
        .buttonStyle(TileButtonStyle(isEditing: isEditing, isDragged: dragged != nil))
        #if os(macOS)
        .simultaneousGesture(mouseHold(metrics: metrics))
        #endif
        .overlay(alignment: .topTrailing) {
            if isEditing { TileMenu(module: module, layout: $layout) }
        }
        .accessibilityAction(named: "Edit home") { isEditing = true }
        .frame(width: frame.width, height: frame.height)
        .position(dragged?.position ?? CGPoint(x: frame.midX, y: frame.midY))
        .zIndex(dragged == nil ? 0 : 1)
    }

    #if os(macOS)
    /// A mouse drag doesn't scroll, so SwiftUI's own gestures work here.
    private func mouseHold(metrics: BentoMetrics) -> some Gesture {
        LongPressGesture()
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let finger?) = value else { return }
                held(drag == nil && !isHolding ? .began(finger.location) : .moved(finger.location), metrics: metrics)
                isHolding = true
            }
            .onEnded { _ in
                isHolding = false
                held(.ended, metrics: metrics)
            }
    }
    #endif

    private func held(_ event: TileHold, metrics: BentoMetrics) {
        let tiles = layout.placements
        switch event {
        case .began(let point):
            guard let placement = metrics.placement(at: point, among: tiles) else { return }
            holds += 1
            isEditing = true
            // The big square always sits at the top, so it can't be dragged.
            guard placement.id != layout.hero else { return }
            let frame = metrics.frame(of: placement)
            drag = TileDrag(
                id: placement.id, position: CGPoint(x: frame.midX, y: frame.midY),
                grab: CGSize(width: point.x - frame.midX, height: point.y - frame.midY)
            )
        case .moved(let point):
            guard var current = drag else { return }
            current.position = CGPoint(x: point.x - current.grab.width, y: point.y - current.grab.height)
            let others = tiles.filter { $0.id != current.id && $0.id != layout.hero }
            let target = metrics.placement(at: point, among: others)?.id
            // Tiles differ in size, so a swap can leave the finger over the same tile. Waiting for a
            // new one stops the two trading places over and over.
            if target != current.target {
                current.target = target
                if let target { layout.move(current.id, to: target) }
            }
            drag = current
        case .ended:
            drag = nil
        }
    }
}

enum TileHold {
    case began(CGPoint), moved(CGPoint), ended
}

#if os(iOS)
/// Watches for a held tile from the scroll view that holds the grid. UIKit settles a hold against a
/// swipe by itself: a finger that moves first scrolls, and one that stays still takes the touch.
/// SwiftUI's hold-then-drag gesture stopped the page scrolling at all.
private struct TileHoldWatcher: UIViewRepresentable {
    let onHold: (TileHold) -> Void

    func makeUIView(context: Context) -> TileHoldView {
        let view = TileHoldView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: TileHoldView, context: Context) {
        view.onHold = onHold
    }
}

private final class TileHoldView: UIView {
    var onHold: (TileHold) -> Void = { _ in }
    private var recognizer: UILongPressGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        guard window != nil,
              let scrollView = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is UIScrollView }) ?? nil
        else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(held))
        scrollView.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        // This view fills the grid, so its coordinates are the grid's.
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began: onHold(.began(point))
        case .changed: onHold(.moved(point))
        default: onHold(.ended)
        }
    }
}
#endif

private let tileShape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)

private struct TileDrag {
    let id: ModuleID
    var position: CGPoint
    let grab: CGSize
    var target: ModuleID?
}

/// Icon, title, and as many of the module's lines as fit, which is how a bigger tile shows more.
struct TileLabel: View {
    let module: ModuleEntry
    let glance: ModuleGlance?
    let isHero: Bool

    var body: some View {
        let theme = Theme.current
        let lines = glance?.lines ?? []
        let isQuiet = glance?.isQuiet ?? false
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: module.systemImage)
                    .accessibilityHidden(true)
                Text(module.name)
                    .lineLimit(1)
            }
            .font(Typeface.callout)
            .foregroundStyle(theme.textSecondary.color)
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: lines.count, to: 0, by: -1)), id: \.self) { count in
                    GlanceLines(lines: Array(lines.prefix(count)), isQuiet: isQuiet, isHero: isHero)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(tileShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([module.name] + lines).joined(separator: ", "))
    }
}

private struct GlanceLines: View {
    let lines: [String]
    let isQuiet: Bool
    let isHero: Bool

    private var leadFont: Font {
        if isQuiet { return Typeface.caption }
        return isHero ? Typeface.title : Typeface.headline
    }

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: isHero ? Space.s2 : Space.s1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let isLead = index == 0 && !isQuiet
                Text(line)
                    .font(index == 0 ? leadFont : isHero ? Typeface.body : Typeface.caption)
                    .foregroundStyle(isLead ? theme.textPrimary.color : theme.textSecondary.color)
                    .lineLimit(index == 0 ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TileButtonStyle: ButtonStyle {
    let isEditing: Bool
    let isDragged: Bool

    private func depth(isPressed: Bool) -> Elevation {
        if isEditing { return isDragged ? .raised : .subtle }
        return isPressed ? .pressed : .raised
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .neumorphic(depth(isPressed: configuration.isPressed), in: tileShape)
            .animation(Motion.instant, value: configuration.isPressed)
    }
}

/// Sizes and moves. Moving from here is the route for anyone who can't drag.
private struct TileMenu: View {
    let module: ModuleEntry
    @Binding var layout: HomeLayout

    var body: some View {
        let id = module.id
        let isHero = layout.hero == id
        Menu {
            ForEach(TileSize.allCases, id: \.self) { size in
                Button {
                    layout.setSize(size, of: id)
                } label: {
                    choice(size.name, isChosen: !isHero && layout.size(of: id) == size)
                }
            }
            Button {
                layout.makeHero(id)
            } label: {
                choice("Big square at top", isChosen: isHero)
            }
            if !isHero {
                Divider()
                Button("Move earlier") { layout.move(id, by: -1) }
                    .disabled(!layout.canMove(id, by: -1))
                Button("Move later") { layout.move(id, by: 1) }
                    .disabled(!layout.canMove(id, by: 1))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Typeface.callout)
                .foregroundStyle(Theme.current.textPrimary.color)
                .frame(width: Space.s6, height: Space.s6)
                .neumorphic(.raised, in: Circle())
                .frame(width: Space.s7, height: Space.s7)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Change \(module.name)")
    }

    @ViewBuilder
    private func choice(_ name: String, isChosen: Bool) -> some View {
        if isChosen {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }
}
