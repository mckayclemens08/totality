import PhotosUI
import SwiftUI
import TotalityCore
import TotalityUI
import UniformTypeIdentifiers

/// A new post: text, up to four photos, one video, or one audio clip. You pick who sees it, each choice with its agreed
/// label, and nothing is sent until you press Post (non-negotiable 6).
struct ComposeView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case text = "Text", photo = "Photo", video = "Video", audio = "Audio"
        var id: String { rawValue }
    }

    let model: SocialModel
    let onClose: () -> Void
    @State private var kind: Kind = .text
    @State private var title = ""
    @State private var text = ""
    @State private var audience: Audience = .everyone
    @State private var posting = false
    @State private var editingCloseFriends = false
    @State private var photos: [Attachment] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var preparing = false
    @State private var photoProblem: String?
    @State private var capture = AudioCapture()
    @State private var importingAudio = false
    @State private var video = VideoPick()

    private var attachments: [Attachment] {
        switch kind {
        case .text: []
        case .photo: photos
        case .video: video.attachments
        case .audio: capture.clip.map { [$0] } ?? []
        }
    }

    var body: some View {
        let theme = Theme.current
        let tags = PostTags.find(in: title + " " + text)
        let attachments = attachments
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack {
                        Button("Cancel", action: onClose).font(Typeface.body).foregroundStyle(theme.textSecondary.color)
                        Spacer()
                        Text("New post").font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Spacer()
                        HeaderPill(posting ? "Posting…" : "Post", isProminent: true) {
                            Task {
                                posting = true
                                if await model.publish(audience, title: title, body: text, attachments: attachments) {
                                    capture.discard()
                                    video.discard()
                                    onClose()
                                }
                                posting = false
                            }
                        }
                        .disabled(posting || preparing || capture.state == .recording || (kind == .video && video.state != .ready)
                                  || PostLimits.problem(title: title, body: text, hasMedia: !attachments.isEmpty) != nil)
                    }
                    HStack(spacing: Space.s2) {
                        ForEach(Kind.allCases) { choice in
                            FilterPill(choice.rawValue, isSelected: kind == choice) { kind = choice }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    switch kind {
                    case .text: EmptyView()
                    case .photo: photoSection
                    case .video: VideoPickSection(pick: video)
                    case .audio: audioSection
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Title").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        TextField("Optional", text: $title).font(Typeface.headline).raisedField()
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(kind == .text ? "Post" : "Caption").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        TextField("What's on your mind? Add #tags anywhere.", text: $text, axis: .vertical)
                            .lineLimit(6...20)
                            .raisedField(.block)
                        HStack {
                            if !tags.isEmpty {
                                Text(tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(theme.accent.color)
                            }
                            Spacer()
                            Text("\(text.count) / \(PostLimits.body)")
                                .foregroundStyle(text.count > PostLimits.body ? theme.danger.color : theme.textSecondary.color)
                        }
                        .font(Typeface.caption)
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
                }
                .padding(Space.s4)
            }
            .background(theme.bg.color.ignoresSafeArea())
            .hidesNavigationBar()
            .sheet(isPresented: $editingCloseFriends) { CloseFriendsView(model: model) { editingCloseFriends = false } }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { Task { await capture.pick(url) } }
            }
            .onChange(of: picked) { _, items in Task { await addPhotos(items) } }
        }
        .interactiveDismissDisabled(!text.isEmpty || !title.isEmpty || !photos.isEmpty || capture.clip != nil || video.source != nil)
        .onDisappear { capture.discard(); video.discard() }
    }

    // MARK: Photos

    private var photoSection: some View {
        let theme = Theme.current
        let tile = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return VStack(alignment: .leading, spacing: Space.s2) {
            ScrollView(.horizontal) {
                HStack(spacing: Space.s3) {
                    ForEach(photos) { photo in
                        ZStack(alignment: .topTrailing) {
                            if let image = PhotoDecode.image(photo.data, side: 320) {
                                Image(image, scale: 1, label: Text("Photo to post")).resizable().scaledToFill()
                                    .frame(width: 104, height: 104).clipShape(tile)
                            }
                            Button { photos.removeAll { $0.id == photo.id } } label: {
                                Image(systemName: "xmark").font(Typeface.micro)
                                    .foregroundStyle(theme.textPrimary.color)
                                    .frame(width: Space.s6, height: Space.s6)
                                    .neumorphic(.subtle, in: Circle())
                            }
                            .buttonStyle(SoftPress())
                            .padding(Space.s1)
                            .accessibilityLabel("Remove this photo")
                        }
                    }
                    if photos.count < MediaLimits.photos {
                        PhotosPicker(selection: $picked, maxSelectionCount: MediaLimits.photos - photos.count, matching: .images) {
                            AddPhotosLabel(count: photos.count, preparing: preparing)
                        }
                        .buttonStyle(SoftPress())
                        .disabled(preparing)
                        .accessibilityLabel("Add photos")
                    }
                }
                .padding(Space.s1)
            }
            .scrollIndicators(.hidden)
            if let photoProblem {
                Text(photoProblem).font(Typeface.caption).foregroundStyle(theme.danger.color)
            } else if photos.isEmpty {
                Text("Up to \(MediaLimits.photos) photos. They're made smaller on this iPhone, and where and when they were taken is left off.")
                    .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        preparing = true
        photoProblem = nil
        for item in items where photos.count < MediaLimits.photos {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw SocialError.failed("That photo couldn't be opened.") }
                let prepared = try await Task.detached(priority: .userInitiated) { try Attachment.photo(data) }.value
                photos.append(prepared)
            } catch {
                photoProblem = (error as? SocialError)?.message ?? "That photo couldn't be opened."
            }
        }
        picked = []
        preparing = false
    }

    // MARK: Audio

    private var audioSection: some View {
        let theme = Theme.current
        let recording = capture.state == .recording
        let seconds = capture.clip?.duration ?? capture.elapsed
        return VStack(spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                if recording { Circle().fill(theme.danger.color).frame(width: Space.s2, height: Space.s2) }
                Text(recording ? "Recording" : capture.clip == nil ? "Up to two minutes" : "Ready to post")
            }
            .font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.accent.color)
            Text(ClipTime.text(seconds)).font(Typeface.display.monospacedDigit())
                .foregroundStyle(theme.textPrimary.color)
            ProgressTrack(fraction: seconds / MediaLimits.audioSeconds) { _ in }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            HStack(spacing: Space.s5) {
                RoundIcon("arrow.counterclockwise", label: "Start over") { capture.discard() }
                    .disabled(capture.clip == nil && !recording)
                Button {
                    if recording { capture.stop() } else { Task { await capture.start() } }
                } label: {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(Typeface.title).foregroundStyle(theme.accentOn.color)
                        .frame(width: 72, height: 72)
                        .background(theme.accent.color, in: Circle())
                }
                .buttonStyle(SoftPress())
                .accessibilityLabel(recording ? "Stop recording" : "Record")
                ListenBack(clip: capture.clip)
            }
            Button("Or upload an audio file") { importingAudio = true }
                .font(Typeface.caption.weight(.semibold)).foregroundStyle(theme.accent.color)
                .disabled(recording)
            if case .failed(let message) = capture.state {
                Text(message).font(Typeface.caption).foregroundStyle(theme.danger.color).multilineTextAlignment(.center)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity)
        .background(theme.highlight.color, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .neumorphic(.raised, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

/// The raised "+" tile at the end of the photo row, with how many are picked.
private struct AddPhotosLabel: View {
    let count: Int
    let preparing: Bool

    var body: some View {
        let theme = Theme.current
        VStack(spacing: Space.s1) {
            if preparing { ProgressView() } else {
                Image(systemName: "plus").font(Typeface.title).foregroundStyle(theme.accent.color)
            }
            Text("\(count) of \(MediaLimits.photos)").font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
        }
        .frame(width: 104, height: 104)
        .neumorphic(.subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// A small raised round button with one symbol.
private struct RoundIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Theme.current.textSecondary.color)
                .frame(width: Space.s7, height: Space.s7)
                .neumorphic(.subtle, in: Circle())
        }
        .buttonStyle(SoftPress())
        .accessibilityLabel(label)
    }
}

/// Plays back the clip you just recorded or picked, before you post it.
private struct ListenBack: View {
    let clip: Attachment?
    @State private var player = ClipPlayer()

    var body: some View {
        RoundIcon(player.playing ? "pause.fill" : "play.fill", label: player.playing ? "Pause" : "Listen back") {
            if let clip { player.toggle(clip.data) }
        }
        .disabled(clip == nil)
        .onChange(of: clip?.id) { player.stop() }
    }
}

/// One audience to choose: its name, who that is, and the label that says how it's kept.
struct AudienceRow: View {
    let audience: Audience
    let isSelected: Bool
    let isAvailable: Bool
    let count: Int?
    let onEdit: (() -> Void)?
    let action: () -> Void

    var body: some View {
        let theme = Theme.current
        HStack(spacing: Space.s3) {
            Button(action: action) {
                HStack(spacing: Space.s3) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? theme.accent.color : theme.textTertiary.color)
                        .font(Typeface.title)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(count.map { "\(audience.name) · \($0)" } ?? audience.name)
                            .font(Typeface.headline).foregroundStyle(theme.textPrimary.color)
                        Text(audience.who).font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
                        Label(audience.label, systemImage: audience.systemImage)
                            .font(Typeface.micro)
                            .foregroundStyle(audience.isEncrypted ? theme.success.color : theme.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SoftPress())
            .disabled(!isAvailable)
            if let onEdit {
                Button("Edit", action: onEdit).font(Typeface.callout).foregroundStyle(theme.accent.color)
            }
        }
        .padding(Space.s3)
        .selectionWash(isSelected, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .neumorphic(isSelected ? .flat : .subtle, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .opacity(isAvailable ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Close friends, picked from the people you follow. Saving changes who's in your encrypted Close-friends room.
struct CloseFriendsView: View {
    let model: SocialModel
    let onClose: () -> Void
    @State private var chosen: Set<String> = []
    @State private var saving = false

    var body: some View {
        let theme = Theme.current
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Button("Cancel", action: onClose).foregroundStyle(theme.textSecondary.color)
                Spacer()
                Text("Close friends").font(Typeface.headline)
                Spacer()
                HeaderPill(saving ? "Saving…" : "Save", isProminent: true) {
                    Task {
                        saving = true
                        if await model.setCloseFriends(chosen) { onClose() }
                        saving = false
                    }
                }
                .disabled(saving)
            }
            Text("Only people on this list see your Close-friends posts. People on the list can see who else is on it, and so can Totality's server.")
                .font(Typeface.caption).foregroundStyle(theme.textSecondary.color)
            if model.followingSet.isEmpty {
                EmptyFeed(systemImage: "person.2", title: "Follow people first", detail: "Close friends are chosen from the people you follow.")
            }
            ScrollView {
                VStack(spacing: Space.s2) {
                    ForEach(model.followingSet.sorted(), id: \.self) { name in
                        Button {
                            if chosen.contains(name) { chosen.remove(name) } else { chosen.insert(name) }
                        } label: {
                            HStack(spacing: Space.s3) {
                                PersonFace(photo: model.photos[name], name: name, diameter: Space.s6)
                                Text(Handle.display(name)).font(Typeface.body).foregroundStyle(theme.textPrimary.color)
                                Spacer()
                                Image(systemName: chosen.contains(name) ? "star.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(name) ? theme.accent.color : theme.textTertiary.color)
                            }
                            .padding(Space.s3)
                            .toggleSurface(chosen.contains(name), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(SoftPress())
                        .accessibilityAddTraits(chosen.contains(name) ? .isSelected : [])
                    }
                }
            }
        }
        .padding(Space.s4)
        .background(theme.bg.color.ignoresSafeArea())
        .onAppear { chosen = model.closeFriends }
    }
}
