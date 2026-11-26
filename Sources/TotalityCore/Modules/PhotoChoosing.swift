import CoreGraphics
import Foundation

/// One library photo or video as the shared chooser lists it. Only an id and what the grid needs: the
/// bytes stay in Photos, sealed, until one is chosen.
public struct ChoosablePhoto: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let isVideo: Bool
    /// Seconds, for a video.
    public let duration: Double?

    public init(id: UUID, date: Date, isVideo: Bool, duration: Double? = nil) {
        self.id = id
        self.date = date
        self.isVideo = isVideo
        self.duration = duration
    }
}

/// What the chooser hands back, already opened on this device. A video is a plain file the caller owns
/// and removes when it's done with it.
public enum ChosenMedia: Sendable {
    /// `type` is the file's type identifier when it's known, like `public.jpeg`.
    case photo(Data, type: String?)
    case video(URL)
}

/// Photos' side of the one photo chooser every module uses. Modules never import Photos: the app hands
/// the chooser down through the environment, and a module only asks for photos and gets media back.
/// Photos keeps its copies sealed, so choosing one decrypts it here, on the device, and nothing leaves
/// until the caller sends it on its own encrypted way.
@MainActor
public protocol PhotoChoosing: AnyObject, Sendable {
    /// Why the library can't be shown right now, or nil when it can.
    var unavailableReason: String? { get }
    /// Everything that can be chosen, newest first. Recently Deleted is left out.
    var choices: [ChoosablePhoto] { get }
    /// Brings the list up to date without starting any backup.
    func refreshChoices() async
    func thumbnail(of id: UUID) async -> CGImage?
    /// The photo's original, opened.
    func photo(_ id: UUID) async throws -> Data
    /// The video as a plain temporary file the caller removes.
    func video(_ id: UUID) async throws -> URL
    /// Keeps copies of what was picked from the iPhone in Photos, sealed.
    func keep(_ media: [ChosenMedia]) async
}
