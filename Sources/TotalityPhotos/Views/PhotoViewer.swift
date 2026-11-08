import SwiftUI
import TotalityUI

/// One photo, full screen. Swipe or use the arrows to move between photos, pinch or double-tap to zoom,
/// and swipe down to close. The thumbnail shows at once, and the original replaces it once it's opened.
struct PhotoViewer: View {
    let model: PhotosModel
    let start: UUID
    let onClose: () -> Void
    @State private var current: UUID?

    var body: some View {
        let theme = Theme.current
        let items = model.items
        ZStack {
            theme.bg.color.ignoresSafeArea()
            #if os(iOS)
            TabView(selection: $current) {
                ForEach(items) { item in
                    ZoomablePhoto(model: model, item: item, onClose: onClose).tag(Optional(item.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            #else
            if let item = items.first(where: { $0.id == current }) {
                ZoomablePhoto(model: model, item: item, onClose: onClose).id(item.id)
            }
            #endif
        }
        .overlay(alignment: .top) { bar(items) }
        .onAppear { current = start }
        #if os(macOS)
        .onKeyPress(.leftArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.rightArrow) { move(1, in: items); return .handled }
        #endif
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func bar(_ items: [PhotoItem]) -> some View {
        let theme = Theme.current
        let item = items.first { $0.id == current }
        return HStack(spacing: Space.s3) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Typeface.body)
                    .frame(width: Space.s7, height: Space.s7)
                    .neumorphic(.subtle, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            Spacer(minLength: 0)
            if let item {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(item.date.formatted(date: .abbreviated, time: .omitted)).font(Typeface.callout)
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s2)
                .neumorphic(.subtle, in: Capsule())
            }
            #if os(macOS)
            Button { move(-1, in: items) } label: { Image(systemName: "chevron.left").frame(width: Space.s7, height: Space.s7) }
                .buttonStyle(.plain).neumorphic(.subtle, in: Circle()).accessibilityLabel("Previous photo")
            Button { move(1, in: items) } label: { Image(systemName: "chevron.right").frame(width: Space.s7, height: Space.s7) }
                .buttonStyle(.plain).neumorphic(.subtle, in: Circle()).accessibilityLabel("Next photo")
            #endif
        }
        .foregroundStyle(theme.textPrimary.color)
        .padding(Space.s4)
    }

    private func move(_ step: Int, in items: [PhotoItem]) {
        guard let index = items.firstIndex(where: { $0.id == current }) else { return }
        let next = index + step
        guard items.indices.contains(next) else { return }
        current = items[next].id
    }
}

/// A photo that zooms. At normal size, a swipe down closes the viewer.
struct ZoomablePhoto: View {
    let model: PhotosModel
    let item: PhotoItem
    let onClose: () -> Void
    @State private var full: CGImage?
    @State private var thumbnail: CGImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let theme = Theme.current
        GeometryReader { geometry in
            ZStack {
                if let image = full ?? thumbnail ?? model.cachedThumbnail(item) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .accessibilityLabel("Photo from \(item.date.formatted(date: .long, time: .shortened))")
                } else {
                    ProgressView()
                }
                if failed {
                    Text("The full photo couldn't be opened. What you see is its thumbnail.")
                        .font(Typeface.caption)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(Space.s3)
                        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(Space.s5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(magnify)
            .simultaneousGesture(drag)
            .onTapGesture(count: 2) {
                withAnimation(Motion.quick) {
                    if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                }
            }
            .task(id: item.id) {
                thumbnail = await model.thumbnail(item)
                let side = Int(max(geometry.size.width, geometry.size.height) * displayScale * 1.5)
                do {
                    full = try await model.fullImage(item, side: max(side, 1_024))
                } catch is CancellationError {
                } catch {
                    failed = true
                }
            }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(settledScale * $0.magnification, 1), 6) }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 { withAnimation(Motion.quick) { reset() } }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                } else if value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) {
                    offset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    settledOffset = offset
                } else if value.translation.height > 120, abs(value.translation.height) > abs(value.translation.width) {
                    onClose()
                } else {
                    withAnimation(Motion.quick) { offset = .zero }
                }
            }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}
