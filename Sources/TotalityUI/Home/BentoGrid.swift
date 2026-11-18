import SwiftUI
import TotalityCore

/// The home page's tiles. A tap opens what's under it, or else the module. Holding any tile enters edit
/// mode and picks it up, so the same press can carry on into a drag. While editing, a tap chooses a
/// tile, which shows its S/M/L switch.
struct BentoGrid: View {
    @Binding var layout: HomeLayout
    let modules: [ModuleEntry]
    let glances: [ModuleID: ModuleGlance]
    let bigTile: (ModuleID, TileSize) -> AnyView?
    /// What a line of a module's glance opens, if anything.
    var lineLink: (ModuleID, Int) -> (@MainActor () -> Void)? = { _, _ in nil }
    let width: CGFloat
    @Binding var isEditing: Bool
    let onOpen: (ModuleID) -> Void
    var onRemove: (ModuleID) -> Void = { _ in }
    @State private var drag: TileDrag?
    /// The tile whose size switch shows while editing.
    @State private var selected: ModuleID?
    /// The module waiting for the person to confirm it comes off Home.
    @State private var removing: ModuleEntry?
    @State private var holds = 0
    #if os(iOS)
    @State private var touched: ModuleID?
    #else
    @State private var isHolding = false
    #endif

    private static let space = "bento"

    var body: some View {
        let metrics = BentoMetrics(width: width)
        let placements = layout.placements
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    if let module = modules.first(where: { $0.id == placement.id }) {
                        tile(module, at: metrics.frame(of: placement), metrics: metrics)
                    }
                }
            }
            .frame(width: width, height: metrics.height(of: placements), alignment: .topLeading)
            .environment(\.liftsTileControls, !isEditing)
            .environment(\.isArrangingHome, isEditing)
            .overlayPreferenceValue(TileLinkKey.self) { links in
                GeometryReader { proxy in
                    let spots = links.map { LinkSpot(link: $0, frame: proxy[$0.bounds]) }
                    if !isEditing {
                        ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                            linkButton(spot, metrics: metrics)
                        }
                    }
                    #if os(iOS)
                    touchArea(metrics: metrics, spots: spots)
                    #endif
                }
            }
            // Above the touch area, so a tile's own buttons and boxes hear their touches.
            .overlayPreferenceValue(TileControlKey.self) { controls in
                GeometryReader { proxy in
                    ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                        let frame = proxy[control.bounds]
                        control.view
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            if isEditing, drag == nil {
                // Above the touch area, or it would take their taps. That's above the tiles too, so
                // they leave while one is carried, or they'd show through it.
                ForEach(placements) { placement in
                    if let module = modules.first(where: { $0.id == placement.id }) {
                        let frame = metrics.frame(of: placement)
                        RemoveTileButton(module: module) { removing = module }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .position(x: frame.minX + Space.s2, y: frame.minY + Space.s2)
                        if selected == module.id {
                            // Straddles the tile's bottom edge at its trailing side. Remove buttons sit
                            // on leading corners, so the row below's never comes under it.
                            Color.clear
                                .frame(width: frame.width, height: frame.height)
                                .overlay(alignment: .bottomTrailing) {
                                    SizeSwitch(module: module, layout: $layout)
                                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                                        .alignmentGuide(.bottom) { $0[VerticalAlignment.center] }
                                        .padding(.trailing, Space.s3)
                                }
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .zIndex(3)
            }
        }
        .frame(width: width, height: metrics.height(of: placements), alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        // No implicit animation on the layout: Home re-reading it, say when a module closes, must not
        // set tiles sliding. Edits animate where they happen.
        .sensoryFeedback(.selection, trigger: holds)
        .onChange(of: isEditing) { if !isEditing { selected = nil } }
        .confirmationDialog(
            "Remove \(removing?.name ?? "") from Home?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { module in
            Button("Remove from Home", role: .destructive) { onRemove(module.id) }
            Button("Cancel", role: .cancel) {}
        } message: { module in
            Text(HomeRemoval.message(for: module))
        }
    }

    private func tile(_ module: ModuleEntry, at frame: CGRect, metrics: BentoMetrics) -> some View {
        let dragged = drag?.id == module.id ? drag : nil
        return Button {
            if isEditing { choose(module.id) } else { onOpen(module.id) }
        } label: {
            let size = layout.contentSize(of: module.id)
            TileLabel(
                module: module, glance: glances[module.id], size: size,
                content: size.flatMap { bigTile(module.id, $0) }, isEditing: isEditing,
                lineLink: { lineLink(module.id, $0) }
            )
        }
        #if os(iOS)
        .buttonStyle(TileButtonStyle(isEditing: isEditing, isDragged: dragged != nil, isTouched: touched == module.id))
        #else
        .buttonStyle(TileButtonStyle(isEditing: isEditing, isDragged: dragged != nil, isTouched: false))
        .simultaneousGesture(mouseHold(metrics: metrics))
        #endif
        .overlay {
            if isEditing, selected == module.id, dragged == nil {
                tileShape.inset(by: -Space.s1)
                    .stroke(Theme.current.accent.color, lineWidth: Metric.selectionOutline)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAction(named: "Edit home") { isEditing = true }
        .accessibilityActions {
            if isEditing {
                ForEach(TileSize.allCases, id: \.self) { size in
                    Button("Make \(size.name.lowercased())") { withMotion(Motion.smooth) { layout.setSize(size, of: module.id) } }
                }
                if layout.canMove(module.id, by: -1) {
                    Button("Move earlier") { withMotion(Motion.smooth) { layout.move(module.id, by: -1) } }
                }
                if layout.canMove(module.id, by: 1) {
                    Button("Move later") { withMotion(Motion.smooth) { layout.move(module.id, by: 1) } }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(dragged?.position ?? CGPoint(x: frame.midX, y: frame.midY))
        // A carried tile stays under the finger; the rest spring aside, and it springs home when let go.
        .transaction { if dragged != nil { $0.animation = nil } }
        .zIndex(dragged == nil ? 0 : 1)
    }

    /// Where VoiceOver and a keyboard reach a link, and on a Mac where the mouse does too. On iPhone
    /// it sits under the touch area, so fingers go through `touchArea`.
    private func linkButton(_ spot: LinkSpot, metrics: BentoMetrics) -> some View {
        Button(action: spot.link.action) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spot.link.name)
        #if os(macOS)
        .simultaneousGesture(mouseHold(metrics: metrics))
        #endif
        .frame(width: spot.frame.width, height: spot.frame.height)
        .position(x: spot.frame.midX, y: spot.frame.midY)
    }

    #if os(iOS)
    private func touchArea(metrics: BentoMetrics, spots: [LinkSpot]) -> some View {
        let tile = { (point: CGPoint) in metrics.placement(at: point, among: layout.placements)?.id }
        return TileTouchArea { point in
            touched = point.flatMap(tile)
        } onTap: { point in
            guard !isEditing else {
                if let id = tile(point) { choose(id) }
                return
            }
            if let spot = spots.first(where: { $0.frame.contains(point) }) {
                spot.link.action()
            } else if let id = tile(point) {
                onOpen(id)
            }
        } onHold: {
            held($0, metrics: metrics)
        }
        // The tiles' own buttons remain for VoiceOver and a keyboard.
        .accessibilityHidden(true)
    }
    #else
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

    /// A second tap on the chosen tile puts its switch away.
    private func choose(_ id: ModuleID) {
        withMotion(Motion.snappy) { selected = selected == id ? nil : id }
    }

    private func held(_ event: TileHold, metrics: BentoMetrics) {
        let tiles = layout.placements
        switch event {
        case .began(let point):
            guard let placement = metrics.placement(at: point, among: tiles) else { return }
            holds += 1
            isEditing = true
            selected = placement.id
            let frame = metrics.frame(of: placement)
            drag = TileDrag(
                id: placement.id, position: CGPoint(x: frame.midX, y: frame.midY),
                grab: CGSize(width: point.x - frame.midX, height: point.y - frame.midY)
            )
        case .moved(let point):
            guard var current = drag else { return }
            current.position = CGPoint(x: point.x - current.grab.width, y: point.y - current.grab.height)
            let others = tiles.filter { $0.id != current.id }
            let target = metrics.placement(at: point, among: others)?.id
            // Tiles differ in size, so a swap can leave the finger over the same tile. Waiting for a
            // new one stops the two trading places over and over.
            if target != current.target {
                current.target = target
                if let target { withMotion(Motion.smooth) { layout.move(current.id, to: target) } }
            }
            drag = current
        case .ended:
            withMotion(Motion.bouncy) { drag = nil }
        }
    }
}

enum TileHold {
    case began(CGPoint), moved(CGPoint), ended
}

#if os(iOS)
/// Takes every touch on the tiles in one plain UIKit view on top of them. A recognizer around the
/// tiles' buttons has to compete with them, and how that goes changes between releases of iOS. On
/// iOS 26 holding did nothing, and handing SwiftUI the recognizer on iOS 18 let the button win.
/// SwiftUI's own hold-then-drag gesture stopped the page scrolling at all. Here UIKit settles a hold
/// against a swipe by itself: a finger that moves first scrolls, and one that stays still takes the touch.
private struct TileTouchArea: UIViewRepresentable {
    let onPress: (CGPoint?) -> Void
    let onTap: (CGPoint) -> Void
    let onHold: (TileHold) -> Void

    func makeUIView(context: Context) -> TileTouchView {
        TileTouchView()
    }

    func updateUIView(_ view: TileTouchView, context: Context) {
        view.onPress = onPress
        view.onTap = onTap
        view.onHold = onHold
    }
}

private final class TileTouchView: UIView {
    var onPress: (CGPoint?) -> Void = { _ in }
    var onTap: (CGPoint) -> Void = { _ in }
    var onHold: (TileHold) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held)))
    }

    required init?(coder: NSCoder) {
        fatalError("Made in code")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onPress(touches.first?.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onPress(nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        onPress(nil)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        onTap(recognizer.location(in: self))
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

private let tileShape = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)

/// A link and where it landed in the grid.
private struct LinkSpot {
    let link: TileLink
    let frame: CGRect
}

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
    let size: TileSize?
    /// The module's own view, which draws its own header with `TileHeader`. Without one, the tile shows
    /// its icon, name and lines.
    let content: AnyView?
    let isEditing: Bool
    var lineLink: (Int) -> (@MainActor () -> Void)? = { _ in nil }

    var body: some View {
        let lines = glance?.lines ?? []
        let isQuiet = glance?.isQuiet ?? false
        Group {
            if let content {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                lineTile(lines: lines, isQuiet: isQuiet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(tileShape)
        .contentShape(tileShape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([module.name] + lines).joined(separator: ", "))
    }

    @ViewBuilder
    private func lineTile(lines: [String], isQuiet: Bool) -> some View {
        if isQuiet || lines.isEmpty {
            quietTile(lines.first)
        } else {
            busyTile(lines: lines, isQuiet: isQuiet)
        }
    }

    /// Nothing to show yet: the module's plain icon centred on its one line, so the tile isn't a label
    /// over an empty middle.
    private func quietTile(_ line: String?) -> some View {
        let theme = Theme.current
        return VStack(spacing: 0) {
            TileHeader(module.name, systemImage: module.systemImage)
            VStack(spacing: Space.s2) {
                Image(systemName: module.systemImage)
                    .font(Typeface.title)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityHidden(true)
                if let line {
                    Text(line)
                        .font(Typeface.tileDetail)
                        .foregroundStyle(theme.textSecondary.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .tileLink(line, action: lineLink(0))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tilePadding()
    }

    private func busyTile(lines: [String], isQuiet: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metric.tileRowGap) {
            TileHeader(module.name, systemImage: module.systemImage)
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: lines.count, to: 0, by: -1)), id: \.self) { count in
                    GlanceLines(lines: Array(lines.prefix(count)), isQuiet: isQuiet, isHero: size == .large, link: lineLink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .tilePadding()
    }
}

private struct GlanceLines: View {
    let lines: [String]
    let isQuiet: Bool
    let isHero: Bool
    let link: (Int) -> (@MainActor () -> Void)?

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tileLink(line, action: link(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TileButtonStyle: ButtonStyle {
    let isEditing: Bool
    let isDragged: Bool
    let isTouched: Bool

    private static let lift: CGFloat = 1.03

    private var depth: Elevation {
        if isEditing { return isDragged ? .raised : .subtle }
        return .raised
    }

    /// A press shrinks the tile a little and lets it fade a touch. Nothing sinks in: the owner doesn't
    /// want a sunken look anywhere (issue 132).
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = (configuration.isPressed || isTouched) && !isEditing
        configuration.label
            .neumorphic(depth, in: tileShape)
            // Picked up, a tile lifts a little toward the finger.
            .scaleEffect(isDragged ? Self.lift : 1)
            .animation(Motion.bouncy, value: isDragged)
            .softPressed(isPressed)
    }
}

/// S, M and L under the chosen tile while Home is edited. The chosen size is filled with the accent.
private struct SizeSwitch: View {
    let module: ModuleEntry
    @Binding var layout: HomeLayout

    var body: some View {
        let theme = Theme.current
        let current = layout.size(of: module.id)
        HStack(spacing: Space.s1 / 2) {
            ForEach(TileSize.allCases, id: \.self) { size in
                let isChosen = current == size
                Button {
                    withMotion(Motion.bouncy) { layout.setSize(size, of: module.id) }
                } label: {
                    Text(size.letter)
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(isChosen ? theme.accentOn.color : theme.textSecondary.color)
                        .padding(.horizontal, Space.s3)
                        .padding(.vertical, Space.s2)
                        .background {
                            if isChosen {
                                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(theme.accent.color)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel("\(size.name) \(module.name) tile")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(Space.s1)
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
