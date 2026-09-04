import AppKit
import Foundation

@MainActor
final class BilibiliThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false

    private static let cache = NSCache<NSURL, NSImage>()
    private var task: URLSessionDataTask?
    private var currentURL: URL?

    func load(_ url: URL) {
        guard currentURL != url else { return }
        task?.cancel()
        currentURL = url
        image = nil

        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            isLoading = false
            return
        }

        guard Self.isAllowed(url) else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        isLoading = true
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let validResponse = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let loadedImage = validResponse && (data?.count ?? 0) <= 8 * 1024 * 1024
                ? data.flatMap(NSImage.init(data:))
                : nil
            DispatchQueue.main.async {
                guard let self, self.currentURL == url else { return }
                self.isLoading = false
                self.image = loadedImage
                if let loadedImage { Self.cache.setObject(loadedImage, forKey: url as NSURL) }
            }
        }
        task?.resume()
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return ["hdslb.com", "bilibili.com", "biliimg.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
