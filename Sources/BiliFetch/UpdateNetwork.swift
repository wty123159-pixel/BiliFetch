import Foundation

struct GitHubReleaseAsset {
    let repository: String
    let name: String
    let tag: String?
    let metadataURL: URL
    let assetPrefix: String

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard parts.count == 6, parts[2] == "releases",
              parts.prefix(2).allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && $0 != "." && $0 != ".." }),
              let name = parts[5].removingPercentEncoding, !name.isEmpty,
              name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\"))) == nil else { return nil }
        let latest = parts[3] == "latest" && parts[4] == "download"
        guard latest || parts[3] == "download", let decodedTag = parts[4].removingPercentEncoding else { return nil }
        repository = "\(parts[0])/\(parts[1])"
        self.name = name
        tag = latest ? nil : decodedTag
        let base = "https://api.github.com/repos/\(repository)/releases"
        guard let metadataURL = URL(string: latest ? "\(base)/latest" : "\(base)/tags/\(parts[4])") else { return nil }
        self.metadataURL = metadataURL
        assetPrefix = "\(base)/assets/"
    }

    func apiURL(in data: Data) throws -> URL {
        struct Release: Decodable {
            struct Asset: Decodable { let id: Int64; let name: String; let state: String; let url: String }
            let tag_name: String
            let draft: Bool
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, tag == nil || tag == release.tag_name,
              let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" }),
              asset.id > 0, asset.url == "\(assetPrefix)\(asset.id)", let url = URL(string: asset.url) else {
            throw AppUpdateError.downloadFailed("官方备用通道尚未提供此更新文件。")
        }
        return url
    }
}

@MainActor
final class UpdateNetwork {
    struct Source {
        let url: URL
        let officialAPI: Bool
        func request(userAgent: String, timeout: TimeInterval = 10) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(officialAPI ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
            return request
        }
    }
    let userAgent: String
    private let session: URLSession
    private var metadata: [URL: (date: Date, data: Data)] = [:]
    private var preferredAPI = Set<String>()
    init(userAgent: String, session: URLSession = .shared) { self.userAgent = userAgent; self.session = session }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.downloadFailed("更新服务器没有返回有效数据。")
        }
        return data
    }
    private func apiSource(_ github: GitHubReleaseAsset) async throws -> Source {
        let cached = metadata[github.metadataURL]
        let releaseData: Data
        if let cached, Date().timeIntervalSince(cached.date) < 60 {
            releaseData = cached.data
        } else {
            var request = Source(url: github.metadataURL, officialAPI: false).request(userAgent: userAgent)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            releaseData = try await data(for: request)
            metadata[github.metadataURL] = (Date(), releaseData)
        }
        return Source(url: try github.apiURL(in: releaseData), officialAPI: true)
    }
    func withFallback<T>(_ url: URL, operation: (Source) async throws -> T) async throws -> T {
        let github = GitHubReleaseAsset(url)
        let order = github.map { preferredAPI.contains($0.repository) } == true ? [true, false] : [false, true]
        var lastError: Error = AppUpdateError.downloadFailed("暂时无法连接更新服务器。")
        for useAPI in order {
            if useAPI && github == nil { continue }
            do {
                let source: Source
                if useAPI, let github { source = try await apiSource(github) }
                else { source = Source(url: url, officialAPI: false) }
                let result = try await operation(source)
                if let github {
                    if useAPI { preferredAPI.insert(github.repository) }
                    else { preferredAPI.remove(github.repository) }
                }
                return result
            } catch { lastError = error }
        }
        throw lastError
    }
    func manifest(_ url: URL, currentVersion: String) async throws -> AppUpdateRelease {
        try await withFallback(url) { source in
            let content = try await self.data(for: source.request(userAgent: self.userAgent))
            return try JSONDecoder().decode(AppUpdateManifest.self, from: content).macOSRelease(currentVersion: currentVersion)
        }
    }
}
