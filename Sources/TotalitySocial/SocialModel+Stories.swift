import CryptoKit
import Foundation
import TotalityCore

/// Stories (issue 149, owner's answer 3): a photo, a video or text that vanishes after 24 hours, in a row of
/// rings at the top of Following. A public story is a row on Totality's server; a Friends or Close-friends
/// story goes into the author's encrypted room like their posts, with its file sealed on this phone first.
/// Every story's file goes on the server's story shelf, which deletes it after a day. Sharing one waits for
/// the person's own press (non-negotiable 6).
extension SocialModel {
    /// Everyone with a live story, yours first.
    public var storyRings: [StoryRing] { StoryRing.rings(stories, me: me) }

    /// Someone's live stories, for the ring on their photo.
    public func ring(for author: String) -> StoryRing? {
        storyRings.first { $0.author.lowercased() == author.lowercased() }
    }

    /// Public stories from the server, encrypted ones from the rooms already read, each marked as opened
    /// or not. Opening an encrypted story is remembered on this phone, by its ID only.
    func loadStories() async {
        let publicOnes = (try? await server.stories()) ?? stories.filter { $0.audience == .everyone }
        let opened = openedStories()
        let now = Date()
        stories = (publicOnes + privateStories).filter { $0.isLive(at: now) }.map { story in
            var story = story
            if opened[story.id] != nil || story.author == me { story.viewed = true }
            return story
        }
    }

    /// Shares a story after the person pressed Share. `attachments` is one photo, or a video and its cover,
    /// or nothing for text.
    public func postStory(_ audience: Audience, kind: SocialStory.Kind, text: String, background: StoryBackground?,
                          attachments: [Attachment]) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var uploaded: [PostMedia] = []
        do {
            if audience.isEncrypted, privatePosts == nil || privateReason != nil { throw SocialError.failed(privateReason ?? "") }
            for item in attachments {
                guard item.data.count <= MediaLimits.most(item.kind) - MediaLimits.sealOverhead else { throw SocialError.refused("That file is too big to share.") }
                var bytes = item.data
                var key: String?
                if audience.isEncrypted { (bytes, key) = try MediaSeal.seal(item.data) }
                let path = try await server.uploadMedia(bytes, contentType: audience.isEncrypted ? "application/octet-stream" : item.contentType,
                                                        store: .stories)
                uploaded.append(PostMedia(kind: item.kind, path: path, size: bytes.count, width: item.width, height: item.height,
                                          duration: item.duration, key: key, store: .stories))
            }
            if let problem = StoryLimits.problem(kind: kind, text: clean, media: uploaded, encrypted: audience.isEncrypted) {
                throw SocialError.refused(problem)
            }
            let background = kind == .text ? (background ?? .accent) : nil
            switch audience {
            case .everyone:
                _ = try await server.postStory(kind: kind, text: clean, background: background, media: uploaded)
                await loadStories()
            case .friends, .closeFriends:
                guard let privatePosts else { throw SocialError.failed(privateReason ?? "") }
                if audience == .friends { try await privatePosts.setMembers(Set(try await server.friends()), of: .friends) }
                _ = try await privatePosts.publishStory(audience, kind: kind, text: clean, background: background, media: uploaded)
                try? await loadFollowing()
            }
            return true
        } catch {
            await removeMedia(uploaded)
            notice = Self.message(error)
            return false
        }
    }

    /// Takes one of your stories down before its day is up, with its file.
    public func deleteStory(_ story: SocialStory) async {
        guard story.author == me else { return }
        do {
            if story.audience == .everyone { try await server.deleteStory(story.id) } else { try await privatePosts?.deleteStory(story) }
            await removeMedia(story.media)
            stories.removeAll { $0.id == story.id }
            privateStories.removeAll { $0.id == story.id }
        } catch {
            notice = Self.message(error)
        }
    }

    /// Marks a story opened. The author is told, through a row only they can read; your own is nothing.
    public func markViewed(_ story: SocialStory) async {
        guard !story.viewed, story.author != me else { return }
        if let i = stories.firstIndex(where: { $0.id == story.id }) { stories[i].viewed = true }
        var opened = openedStories()
        opened[story.id] = story.expires.timeIntervalSince1970
        rememberOpened(opened)
        try? await server.viewStory(story.id, author: story.author)
    }

    /// Who opened one of your stories. For an encrypted one, only people still in its room count, so
    /// nobody else's claim to have seen it shows.
    public func viewers(of story: SocialStory) async -> [String] {
        guard story.author == me, var found = try? await server.storyViewers(story.id) else { return [] }
        if story.audience.isEncrypted {
            guard let members = try? await privatePosts?.members(story.audience) else { return [] }
            found = found.filter(members.contains)
        }
        return found
    }

    // MARK: Opened stories, on this phone

    /// Story IDs and when each one's day ends. Nothing else about the story is kept.
    func openedStories() -> [UUID: Double] {
        guard let me, let saved = remembered.dictionary(forKey: "social.openedStories." + me) as? [String: Double] else { return [:] }
        let now = Date().timeIntervalSince1970
        var found: [UUID: Double] = [:]
        for (id, until) in saved where until > now { if let id = UUID(uuidString: id) { found[id] = until } }
        return found
    }

    private func rememberOpened(_ opened: [UUID: Double]) {
        guard let me else { return }
        remembered.set(Dictionary(uniqueKeysWithValues: opened.map { ($0.key.uuidString, $0.value) }), forKey: "social.openedStories." + me)
    }
}

/// Videos opened for playing, as files in this app's own caches. A player needs a file, and a sealed video
/// is opened on this phone first, so the file holds the opened video: it's written with complete file
/// protection, named for a hash of its address, and only the last few are kept. They're all deleted when
/// the account changes.
@MainActor
final class VideoFiles {
    static let most = 6
    private var order: [String] = []
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("social-video", isDirectory: true)
        // Anything left from an earlier launch goes, so nothing outlives the account it came from.
        try? FileManager.default.removeItem(at: self.folder)
    }

    private func name(_ path: String) -> URL {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".mp4")
    }

    func file(for path: String) -> URL? {
        let url = name(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        order.removeAll { $0 == path }
        order.append(path)
        return url
    }

    func keep(_ data: Data, for path: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = name(path)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > Self.most { try? FileManager.default.removeItem(at: name(order.removeFirst())) }
        return url
    }

    func clear() {
        order = []
        try? FileManager.default.removeItem(at: folder)
    }
}
