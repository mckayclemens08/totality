import AVFoundation
import CoreTransferable
import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers

// MARK: Colours

extension StoryBackground {
    /// Each swatch is a theme's own accent from `Tokens.swift`, with that theme's text-on-accent colour.
    var fill: ColorToken {
        switch self {
        case .accent: Theme.current.accent
        case .blush: Theme.blush.accent
        case .sage: Theme.sage.accent
        case .lilac: Theme.lilac.accent
        case .slate: Theme.light.textSecondary
        }
    }

    var ink: ColorToken { self == .accent ? Theme.current.accentOn : Theme.light.accentOn }

    var name: String {
        switch self {
        case .accent: "Theme colour"
        case .blush: "Red"
        case .sage: "Green"
        case .lilac: "Purple"
        case .slate: "Grey"
        }
    }
}

// MARK: Rings

/// A person's photo with the story ring round it: the accent while something's new, a soft grey once
/// you've seen it all, and nothing when they have no story.
struct StoryFace: View {
    let photo: Data?
    let name: String
    let ring: StoryRing?
    var diameter: CGFloat = Space.s7

    var body: some View {
        let theme = Theme.current
        let width = max(2, diameter / 18)
        PersonFace(photo: photo, name: name, diameter: diameter)
            .padding(width + 2)
            .overlay {
                if let ring {
                    Circle().strokeBorder(ring.allViewed ? theme.highlightStrong.color : theme.accent.color, lineWidth: width)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(ring == nil ? name : "\(name), \(ring!.allViewed ? "story seen" : "new story")")
    }
}

/// The row of story circles at the top of Following. Yours comes first, with a + for a new story.
struct StoryRowView: View {
    let model: SocialModel
    let onOpen: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        let theme = Theme.current
        let rings = model.storyRings
        let meKey = model.me?.lowercased()
        let mine = meKey.flatMap { key in rings.first { $0.author.lowercased() == key } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.s3) {
                VStack(spacing: Space.s1) {
                    Button {
                        if let mine { onOpen(mine.author) } else { onNew() }
                    } label: {
                        StoryFace(photo: model.me.flatMap { model.photos[$0] }, name: model.me ?? "You", ring: mine, diameter: Space.s7 + Space.s1)
                    }
                    .buttonStyle(SoftPress())
                    .overlay(alignment: .bottomTrailing) {
                        Button(action: onNew) {
                            Image(systemName: "plus").font(Typeface.micro.weight(.bold)).foregroundStyle(theme.accentOn.color)
                                .frame(width: Space.s5, height: Space.s5)
                                .background(theme.accent.color, in: Circle())
                                // A full-size target, so a second story is never one missed tap away from opening your first.
                                .padding(Space.s2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SoftPress())
                        .accessibilityLabel("New story")
                    }
                    .accessibilityLabel(mine == nil ? "New story" : "Your story")
                    Text("Your story").font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                }
                .frame(width: Space.s8)
                ForEach(rings.filter { $0.author.lowercased() != meKey }) { ring in
                    Button { onOpen(ring.author) } label: {
                        VStack(spacing: Space.s1) {
                            StoryFace(photo: model.photos[ring.author], name: ring.name, ring: ring, diameter: Space.s7 + Space.s1)
                            Text(ring.author).font(Typeface.micro).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                            if let audience = ring.stories.last?.audience, audience.isEncrypted {
                                Text(audience.name).font(Typeface.micro).foregroundStyle(theme.success.color).lineLimit(1)
                            }
                        }
                        .frame(width: Space.s8)
                    }
                    .buttonStyle(SoftPress())
                }
            }
            .padding(.vertical, Space.s2)
            .padding(.horizontal, Space.s1)
        }
    }
}

// MARK: Viewer

/// What the viewer is playing: the rings as they were when it opened, and whose to start with.
struct StoryWatch: Identifiable {
    let id = UUID()
    let rings: [StoryRing]
    let author: String
}

extension View {
    /// The story viewer, full screen on iPhone.
    func storyCover<Content: View>(item: Binding<StoryWatch?>, @ViewBuilder content: @escaping (StoryWatch) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

/// Stories full screen. Photos and text stay five seconds, a video for its length. Tap the right side for
/// the next, the left to go back, hold to pause, swipe down to close. One person's end leads into the next.
struct StoryViewer: View {
    let model: SocialModel
    /// Taken when it opened, so marking stories seen doesn't reshuffle what's playing.
    let rings: [StoryRing]
    let onClose: () -> Void
    @State private var ringIndex: Int
    @State private var storyIndex: Int
    @State private var progress: Double = 0
    @State private var holding = false
    @State private var ready = false
    @State private var showingViewers = false
    @State private var confirmingDelete = false
    @State private var drag: CGFloat = 0

    init(model: SocialModel, rings: [StoryRing], start author: String, onClose: @escaping () -> Void) {
        self.model = model
        self.rings = rings
        self.onClose = onClose
        let index = rings.firstIndex { $0.author == author } ?? 0
        _ringIndex = State(initialValue: index)
        _storyIndex = State(initialValue: rings.indices.contains(index) ? rings[index].firstUnviewed : 0)
    }

    private var story: SocialStory? {
        guard rings.indices.contains(ringIndex), rings[ringIndex].stories.indices.contains(storyIndex) else { return nil }
        return rings[ringIndex].stories[storyIndex]
    }

    private var paused: Bool { holding || showingViewers || confirmingDelete }

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s2) {
            if let story {
                bars
                top(story)
                stage(story)
                foot(story)
            } else {
                EmptyFeed(systemImage: "circle.dashed", title: "That story is gone", detail: "Stories vanish after 24 hours.")
                HeaderPill("Close", isProminent: true, action: onClose)
                Spacer()
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.bottom, Space.s2)
        .background(theme.bg.color.ignoresSafeArea())
        .offset(y: max(0, drag))
        .gesture(DragGesture(minimumDistance: 20)
            .onChanged { drag = $0.translation.height }
            .onEnded { if $0.translation.height > 120 { onClose() } else { withAnimation(Motion.smooth) { drag = 0 } } })
        .task(id: story?.id) {
            guard let story else { return }
            progress = 0
            ready = story.kind != .video
            await model.markViewed(story)
            let step = 0.05
            while !Task.isCancelled && progress < 1 {
                try? await Task.sleep(for: .milliseconds(Int(step * 1000)))
                if !paused && ready { progress += step / story.showFor }
            }
            if !Task.isCancelled { next() }
        }
        .sheet(isPresented: $showingViewers) {
            if let story { StoryViewersSheet(model: model, story: story) { showingViewers = false } }
        }
        .confirmationDialog("Delete this story?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete story", role: .destructive) {
                guard let story else { return }
                Task {
                    await model.deleteStory(story)
                    onClose()
                }
            }
        } message: {
            Text("It's gone for everyone straight away, and so is its file.")
        }
    }

    private var bars: some View {
        let theme = Theme.current
        let stories = rings[ringIndex].stories
        return HStack(spacing: Space.s1) {
            ForEach(stories.indices, id: \.self) { index in
                GeometryReader { geo in
                    let fraction = index < storyIndex ? 1 : index == storyIndex ? progress : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.highlightStrong.color)
                        Capsule().fill(theme.accent.color).frame(width: geo.size.width * min(1, fraction))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.top, Space.s2)
        .accessibilityElement()
        .accessibilityLabel("Story \(storyIndex + 1) of \(stories.count)")
    }

    private func top(_ story: SocialStory) -> some View {
        let theme = Theme.current
        return HStack(spacing: Space.s2) {
            PersonFace(photo: model.photos[story.author], name: story.displayName, diameter: Space.s6)
            VStack(alignment: .leading, spacing: 0) {
                Text(story.author == model.me ? "Your story" : story.displayName).font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Text(story.date.formatted(.relative(presentation: .numeric))).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                    .frame(width: Metric.headerButton, height: Metric.headerButton)
                    .neumorphic(.subtle, in: Circle())
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel("Close")
        }
    }

    private func stage(_ story: SocialStory) -> some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            switch story.kind {
            case .text:
                let background = story.background ?? .accent
                Rectangle().fill(background.fill.color)
                Text(story.text)
                    .font(Typeface.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(background.ink.color)
                    .padding(Space.s5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .photo:
                Rectangle().fill(theme.surface.color)
                if let photo = story.photo { PostPhoto(model: model, item: photo, side: 1600, fit: true) }
            case .video:
                Rectangle().fill(theme.surface.color)
                if let video = story.video {
                    StoryVideo(model: model, item: video, paused: paused) { ready = true }
                        .id(story.id)
                }
            }
            if story.kind != .text, !story.text.isEmpty {
                Text(story.text)
                    .font(Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(Space.s3)
                    .background(theme.surface.color.opacity(0.85), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .padding(Space.s3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .neumorphic(.raised, in: shape)
        .overlay {
            // Tap the left third to go back, anywhere else for the next; hold to pause.
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        if point.x < geo.size.width / 3 { previous() } else { next() }
                    }
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) {} onPressingChanged: { holding = $0 }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(story.kind == .text ? story.text : "\(story.kind.name) story\(story.text.isEmpty ? "" : ": \(story.text)")")
        .accessibilityAction(named: "Next") { next() }
        .accessibilityAction(named: "Previous") { previous() }
    }

    private func foot(_ story: SocialStory) -> some View {
        let theme = Theme.current
        let left = max(0, story.expires.timeIntervalSinceNow)
        return HStack(spacing: Space.s2) {
            if story.author == model.me {
                HeaderPill("Seen by…") { showingViewers = true }
                HeaderPill("Delete") { confirmingDelete = true }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Label(story.audience.label, systemImage: story.audience.systemImage)
                    .font(Typeface.micro)
                    .foregroundStyle(story.audience.isEncrypted ? theme.success.color : theme.textSecondary.color)
                Text("Vanishes in \(Int((left / 3600).rounded(.up)))h").font(Typeface.micro).foregroundStyle(theme.textSecondary.color)
            }
            .multilineTextAlignment(.trailing)
        }
    }

    private func next() {
        if storyIndex + 1 < rings[ringIndex].stories.count {
            storyIndex += 1
        } else if ringIndex + 1 < rings.count {
            ringIndex += 1
            storyIndex = rings[ringIndex].firstUnviewed
        } else {
            onClose()
        }
    }

    private func previous() {
        if storyIndex > 0 {
            storyIndex -= 1
        } else if ringIndex > 0 {
            ringIndex -= 1
            storyIndex = max(0, rings[ringIndex].stories.count - 1)
        } else {
            progress = 0
        }
    }
}

/// Who opened your story. Only you ever see this list.
struct StoryViewersSheet: View {
    let model: SocialModel
    let story: SocialStory
    let onClose: () -> Void
    @State private var people: [String]?

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text(people.map { $0.count == 1 ? "Seen by 1" : "Seen by \($0.count)" } ?? "Seen by")
                    .font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                Spacer()
                Button("Done", action: onClose).foregroundStyle(theme.accent.color)
            }
            Text("Only you can see who opened your story.").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if let people {
                if people.isEmpty {
                    EmptyFeed(systemImage: "eye", title: "No one yet", detail: "People who open it show here.")
                } else {
                    ScrollView {
                        VStack(spacing: Space.s2) {
                            ForEach(people, id: \.self) { name in
                                HStack(spacing: Space.s3) {
                                    PersonFace(photo: model.photos[name], name: name, diameter: Space.s6)
                                    Text(Handle.display(name)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                    Spacer()
                                }
                                .padding(Space.s3)
                                .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            }
                        }
                        .padding(Space.s1)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
        .task { people = await model.viewers(of: story) }
    }
}

// MARK: Picking a video

/// Picking, trimming and making small one video, for a post or a story. The original stays where it was;
/// only the made-small copy of the kept part is ever sent.
@MainActor
@Observable
final class VideoPick {
    enum State: Equatable { case empty, preparing, ready, failed(String) }
    private(set) var state: State = .empty
    private(set) var source: URL?
    private(set) var length: Double = 0
    var range = TrimRange(start: 0, end: 0)
    private(set) var prepared: VideoPrep.Prepared?
    private(set) var originalBytes = 0

    var attachments: [Attachment] { prepared.map { [$0.video, $0.cover] } ?? [] }

    /// Takes a video the shared chooser opened as a file. Nil means it couldn't be opened.
    func pick(_ file: URL?) async {
        discard()
        state = .preparing
        do {
            guard let file else { throw SocialError.failed("That video couldn't be opened.") }
            source = file
            originalBytes = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
            length = try await VideoPrep.length(of: file)
            range = TrimRange.clamped(start: 0, end: length, length: length)
            await prepare()
        } catch {
            state = .failed((error as? SocialError)?.message ?? "That video couldn't be opened.")
        }
    }

    /// Makes the kept part small. Run again after the trim changes.
    func prepare() async {
        guard let source else { return }
        state = .preparing
        prepared = nil
        range = TrimRange.clamped(start: range.start, end: range.end, length: length)
        do {
            let url = source
            let keep = range
            prepared = try await Task.detached(priority: .userInitiated) { try await VideoPrep.prepare(url, keeping: keep) }.value
            state = .ready
        } catch {
            state = .failed((error as? SocialError)?.message ?? "That video couldn't be made smaller.")
        }
    }

    func discard() {
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
        prepared = nil
        length = 0
        originalBytes = 0
        state = .empty
    }
}

/// The video part of a composer: pick, preview the cover, drag the start and end, and see the size it'll
/// go up at.
struct VideoPickSection: View {
    let pick: VideoPick
    @State private var choosing = false
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s3) {
            if let cover = pick.prepared?.cover, let image = PhotoDecode.image(cover.data, side: 800) {
                Image(image, scale: 1, label: Text("Video cover")).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(alignment: .topLeading) { VideoChip(text: ClipTime.text(pick.range.length), systemImage: "video").padding(Space.s2) }
            }
            if pick.length > 0 {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Start \(ClipTime.text(start))").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    Slider(value: $start, in: 0...max(pick.length, 0.1)) { editing in if !editing { apply() } }
                        .tint(theme.accent.color)
                        .accessibilityLabel("Start of the part to keep")
                    Text("End \(ClipTime.text(end)) · \(ClipTime.text(max(0, end - start))) kept, up to 3:00")
                        .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    Slider(value: $end, in: 0...max(pick.length, 0.1)) { editing in if !editing { apply() } }
                        .tint(theme.accent.color)
                        .accessibilityLabel("End of the part to keep")
                }
            }
            HStack(spacing: Space.s2) {
                Button { choosing = true } label: {
                    PickLabel(text: pick.source == nil ? "Choose a video" : "Choose another")
                }
                .buttonStyle(SoftPress())
                .disabled(pick.state == .preparing)
                Spacer(minLength: 0)
                if pick.state == .preparing { ProgressView() }
            }
            switch pick.state {
            case .ready:
                if let video = pick.prepared?.video {
                    Text("Made smaller on this iPhone: \(Self.size(pick.originalBytes)) → \(Self.size(video.data.count))")
                        .font(Typeface.caption.monospacedDigit()).foregroundStyle(theme.success.color)
                }
            case .preparing:
                Text("Making it smaller on this iPhone…").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            case .failed(let message):
                Text(message).font(Typeface.caption).foregroundStyle(theme.danger.color)
            case .empty:
                Text("Up to three minutes. It's made smaller on this iPhone, and where it was filmed and the camera's details are left off.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.highlight.color, in: shape)
        .neumorphic(.raised, in: shape)
        .photoChooser(isPresented: $choosing, kinds: .videos) { media in
            if case .video(let url)? = media.first { await pick.pick(url) } else { await pick.pick(nil) }
            start = pick.range.start
            end = pick.range.end
        }
        .onAppear { start = pick.range.start; end = pick.range.end }
    }

    private func apply() {
        if end < start { end = start }
        if end - start > MediaLimits.videoSeconds { end = start + MediaLimits.videoSeconds }
        pick.range = TrimRange(start: start, end: end)
        Task {
            await pick.prepare()
            start = pick.range.start
            end = pick.range.end
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The raised "Choose a video" capsule.
private struct PickLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "video.badge.plus")
            .font(Typeface.callout.weight(.semibold)).foregroundStyle(Theme.current.accent.color)
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .neumorphic(.subtle, in: Capsule())
    }
}

/// The photo picked for a story, or the raised tile to pick one.
private struct StoryPhotoTile: View {
    let photo: Attachment?

    var body: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        ZStack {
            if let photo, let image = PhotoDecode.image(photo.data, side: 800) {
                Image(image, scale: 1, label: Text("Photo for the story")).resizable().scaledToFit()
            } else {
                VStack(spacing: Space.s2) {
                    Image(systemName: "photo.badge.plus").font(Typeface.title).foregroundStyle(theme.accent.color)
                    Text("Choose a photo").font(Typeface.callout).foregroundStyle(theme.textSecondary.color)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 260)
        .clipShape(shape)
        .neumorphic(.raised, in: shape)
    }
}

// MARK: New story

/// A new story: a photo, a video or text on a colour. Picked audience, its label, and nothing goes up until
/// you press Share (non-negotiable 6).
struct StoryComposer: View {
    let model: SocialModel
    let onClose: () -> Void
    @State private var kind: SocialStory.Kind = .text
    @State private var text = ""
    @State private var background: StoryBackground = .accent
    @State private var audience: Audience = .everyone
    @State private var photo: Attachment?
    @State private var choosingPhoto = false
    @State private var photoProblem: String?
    @State private var video = VideoPick()
    @State private var sharing = false
    @State private var editingCloseFriends = false

    private var attachments: [Attachment] {
        switch kind {
        case .text: []
        case .photo: photo.map { [$0] } ?? []
        case .video: video.attachments
        }
    }

    private var canShare: Bool {
        if sharing { return false }
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= StoryLimits.text
        case .photo: return photo != nil && text.count <= StoryLimits.text
        case .video: return video.state == .ready && text.count <= StoryLimits.text
        }
    }

    var body: some View {
        let theme = Theme.current
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack {
                    Button("Cancel", action: onClose).font(Typeface.body).foregroundStyle(theme.textSecondary.color)
                    Spacer()
                    Text("New story").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                    Spacer()
                    HeaderPill(sharing ? "Sharing…" : "Share", isProminent: true) {
                        Task {
                            sharing = true
                            if await model.postStory(audience, kind: kind, text: text, background: background, attachments: attachments) {
                                video.discard()
                                onClose()
                            }
                            sharing = false
                        }
                    }
                    .disabled(!canShare)
                }
                HStack(spacing: Space.s2) {
                    ForEach(SocialStory.Kind.allCases) { choice in
                        FilterPill(choice.name, isSelected: kind == choice) { kind = choice }.frame(maxWidth: .infinity)
                    }
                }
                switch kind {
                case .text: textCard
                case .photo: photoSection
                case .video: VideoPickSection(pick: video)
                }
                if kind != .text {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Caption").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        TextField("Optional", text: $text, axis: .vertical).lineLimit(1...4).raisedField(.block)
                    }
                }
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Who can see this").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    ForEach(Audience.allCases) { choice in
                        AudienceRow(
                            audience: choice, isSelected: audience == choice,
                            isAvailable: !choice.isEncrypted || model.privateReason == nil,
                            count: choice == .closeFriends ? model.closeFriends.count : nil,
                            onEdit: choice == .closeFriends && model.privateReason == nil ? { editingCloseFriends = true } : nil
                        ) { audience = choice }
                    }
                    if let reason = model.privateReason {
                        Text(reason).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                    }
                }
                Text("Gone after 24 hours. Totality's server deletes the story and its file then. Only you see who opened it.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
            .padding(Space.s4)
        }
        .background(theme.bg.color.ignoresSafeArea())
        .sheet(isPresented: $editingCloseFriends) { CloseFriendsView(model: model) { editingCloseFriends = false } }
        .photoChooser(isPresented: $choosingPhoto) { media in
            photoProblem = nil
            do {
                guard case .photo(let data, _)? = media.first else { throw SocialError.failed("That photo couldn't be opened.") }
                photo = try await Task.detached(priority: .userInitiated) { try Attachment.photo(data) }.value
            } catch {
                photoProblem = (error as? SocialError)?.message ?? "That photo couldn't be opened."
            }
        }
        .interactiveDismissDisabled(!text.isEmpty || photo != nil || video.source != nil)
        .onDisappear { video.discard() }
    }

    private var textCard: some View {
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        return VStack(alignment: .leading, spacing: Space.s3) {
            TextField("Say something", text: $text, axis: .vertical)
                .font(Typeface.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(background.ink.color)
                .tint(background.ink.color)
                .lineLimit(3...8)
                .padding(Space.s5)
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(background.fill.color, in: shape)
                .neumorphic(.raised, in: shape)
            HStack(spacing: Space.s3) {
                ForEach(StoryBackground.allCases) { choice in
                    Button { background = choice } label: {
                        Circle().fill(choice.fill.color)
                            .frame(width: Space.s6, height: Space.s6)
                            .padding(3)
                            .overlay { if background == choice { Circle().strokeBorder(theme.textPrimary.color, lineWidth: 2) } }
                    }
                    .buttonStyle(SoftPress())
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(background == choice ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Text("\(text.count) / \(StoryLimits.text)").font(Typeface.caption)
                    .foregroundStyle(text.count > StoryLimits.text ? theme.danger.color : theme.textSecondary.color)
            }
        }
    }

    private var photoSection: some View {
        let theme = Theme.current
        return VStack(alignment: .leading, spacing: Space.s2) {
            Button { choosingPhoto = true } label: {
                StoryPhotoTile(photo: photo)
            }
            .buttonStyle(SoftPress())
            .accessibilityLabel(photo == nil ? "Choose a photo" : "Choose another photo")
            if let photoProblem {
                Text(photoProblem).font(Typeface.caption).foregroundStyle(theme.danger.color)
            } else {
                Text("Made smaller on this iPhone, and where and when it was taken is left off.").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
    }
}
