import ImageIO
import SwiftUI
import TotalityUI

/// Privacy-safe ephemeral thumbnail cache (`URLSessionConfiguration.ephemeral`, no cookies, HTTPS only).
@MainActor
private final class NewsStoryImageCache {
    static let shared = NewsStoryImageCache()
    private let cache = NSCache<NSURL, CGImage>()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    func cached(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(url: URL, maxPixel: Int) async -> CGImage? {
        if let existing = cache.object(forKey: url as NSURL) { return existing }
        guard NewsNetwork.allows(url) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("TotalityNews/1.0", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await Self.session.bytes(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.expectedContentLength <= 4 * 1024 * 1024
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < 4 * 1024 * 1024 else { return nil }
                data.append(byte)
            }
        } catch {
            return nil
        }
        let decoded: CGImage? = await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let decoded {
            cache.setObject(decoded, forKey: url as NSURL)
        }
        return decoded
    }
}

/// Real article photo when available from RSS / GDELT `socialimage` (fetched without cookies),
/// falling back gracefully to an editorial vector emblem when an article has no image.
struct NewsStoryArtwork: View {
    let article: NewsArticle
    let featured: Bool
    @State private var loadedImage: CGImage?
    @State private var loadedURL: URL?

    private var symbol: String {
        let source = article.source.lowercased()
        let headline = article.title.lowercased()
        if source.contains("weather") || headline.contains("advisory") || headline.contains("weather") { return "cloud.sun" }
        if source.contains("nasa") || headline.contains("space") { return "sparkles" }
        if source.contains("federal reserve") || headline.contains("economy") { return "chart.line.uptrend.xyaxis" }
        if source.contains("earthquake") { return "waveform.path" }
        if source.contains("census") { return "person.3" }
        return "globe.americas"
    }

    var body: some View {
        let theme = Theme.current
        ZStack {
            if let image = displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [theme.highlightStrong.color, theme.highlight.color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if featured {
                    Circle().fill(theme.highlight.color)
                        .frame(width: Space.s8 * 3, height: Space.s8 * 3)
                        .offset(x: Space.s8 * 2, y: Space.s6)
                    Circle().fill(theme.highlightStrong.color)
                        .frame(width: Space.s8 * 2, height: Space.s8 * 2)
                        .offset(x: -Space.s8 * 2, y: -Space.s6)
                }
                Image(systemName: symbol)
                    .font(featured ? Typeface.display : Typeface.headline)
                    .foregroundStyle(theme.textPrimary.color)
            }
        }
        .frame(width: featured ? nil : Space.s7, height: featured ? Space.s8 * 3 : Space.s7)
        .frame(maxWidth: featured ? .infinity : nil)
        .clipped()
        .clipShape(.rect(cornerRadius: Radius.md))
        .accessibilityHidden(true)
        .task(id: article.imageURL) {
            guard let url = article.imageURL else {
                loadedImage = nil
                loadedURL = nil
                return
            }
            if let cached = NewsStoryImageCache.shared.cached(for: url) {
                loadedURL = url
                loadedImage = cached
                return
            }
            loadedImage = nil
            loadedURL = url
            let img = await NewsStoryImageCache.shared.load(url: url, maxPixel: featured ? 1000 : 320)
            guard !Task.isCancelled, article.imageURL == url else { return }
            loadedImage = img
        }
    }

    private var displayedImage: CGImage? {
        guard let url = article.imageURL else { return nil }
        if loadedURL == url, let loadedImage { return loadedImage }
        return NewsStoryImageCache.shared.cached(for: url)
    }
}
