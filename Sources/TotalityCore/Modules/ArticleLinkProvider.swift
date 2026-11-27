import Foundation

/// Resolves a reference to a publisher's article on the device.
public protocol ArticleLinkProvider: ContentHandler {
    func articleURL(for ref: ContentRef) async -> URL?
}
