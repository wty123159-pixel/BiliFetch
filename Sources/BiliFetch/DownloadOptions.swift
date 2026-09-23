import Foundation

enum DownloadScope: String, CaseIterable, Identifiable {
    case automatic
    case current
    case collection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "智能识别"
        case .current: return "仅当前视频"
        case .collection: return "整个合集"
        }
    }

    func downloadsPlaylist(for url: URL) -> Bool {
        guard URLClassifier.isBilibili(url) else { return false }
        switch self {
        case .current:
            return false
        case .collection:
            return true
        case .automatic:
            return URLClassifier.looksLikeCollection(url)
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best
    case p1080
    case p720
    case p480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "当前可用最高画质"
        case .p1080: return "1080p 以内"
        case .p720: return "720p 以内"
        case .p480: return "480p 以内"
        }
    }

    var formatSelector: String {
        let combined = "bv*+ba/b"
        switch self {
        case .best:
            return combined
        case .p1080:
            return boundedFormat(maxShortEdge: 1080, finalFallback: combined)
        case .p720:
            return boundedFormat(maxShortEdge: 720, finalFallback: combined)
        case .p480:
            return boundedFormat(maxShortEdge: 480, finalFallback: combined)
        }
    }

    private func boundedFormat(maxShortEdge value: Int, finalFallback: String) -> String {
        // Bilibili's portrait videos express quality on the width rather than
        // the height. Try both orientations before falling back, so one odd
        // episode cannot abort an otherwise valid collection.
        let avcLandscape = "bv*[height<=\(value)][vcodec^=avc]+ba[acodec^=mp4a]"
        let avcPortrait = "bv*[width<=\(value)][vcodec^=avc]+ba[acodec^=mp4a]"
        let anyLandscape = "bv*[height<=\(value)]+ba"
        let anyPortrait = "bv*[width<=\(value)]+ba"
        let combinedLandscape = "b[height<=\(value)]"
        let combinedPortrait = "b[width<=\(value)]"
        return [
            avcLandscape,
            avcPortrait,
            anyLandscape,
            anyPortrait,
            combinedLandscape,
            combinedPortrait,
            finalFallback
        ].joined(separator: "/")
    }
}

enum BrowserCookies: String, CaseIterable, Identifiable {
    case none
    case safari
    case chrome
    case edge
    case firefox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不使用登录状态"
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        case .firefox: return "Firefox"
        }
    }
}

enum DownloadEngine: String, CaseIterable, Identifiable {
    case aria2
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aria2: return "高速（aria2）"
        case .native: return "标准（yt-dlp）"
        }
    }
}

enum URLClassifier {
    static func validatedURL(from text: String) -> URL? {
        // The same URL can appear twice in Markdown link text. Multiple
        // different links are ambiguous and must not silently choose a work.
        let pattern = #"(?<![A-Za-z0-9_:/@?=&%.-])https?://[^\s<>\"'`\[\](){}，。！？；、【】「」《》（）…]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var urls: [URL] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let url = validatedSingleURL(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!"))) else { continue }
            if !urls.contains(url) { urls.append(url) }
        }
        return urls.count == 1 ? urls[0] : nil
    }

    private static func validatedSingleURL(_ text: String) -> URL? {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == (scheme == "https" ? 443 : 80),
              let host = components.host?.lowercased(),
              isAllowed(host: host) else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.port = nil
        if components.path.isEmpty { components.path = "/" }
        components.fragment = nil
        guard let url = components.url else { return nil }
        if host == "weixin.qq.com" || host == "channels.weixin.qq.com" {
            return isWeChat(url) ? url : nil
        }
        return url
    }

    static func isAllowed(host: String) -> Bool {
        if host == "weixin.qq.com" || host == "channels.weixin.qq.com" { return true }
        return ["bilibili.com", "b23.tv", "bilibili.tv", "douyin.com", "iesdouyin.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func isBilibili(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["bilibili.com", "b23.tv", "bilibili.tv"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isDouyin(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["douyin.com", "iesdouyin.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func weChatCaptureID(_ url: URL) -> String? {
        guard url.scheme == "https", url.host == "channels.weixin.qq.com",
              url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/bilifetch-capture/[a-f0-9]{32}$"#, options: .regularExpression) != nil else { return nil }
        return url.lastPathComponent
    }

    static func isWeChat(_ url: URL) -> Bool {
        weChatCaptureID(url) != nil ||
        (url.host == "weixin.qq.com" && url.path.range(of: #"^/sph/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil)
    }

    static func looksLikeCollection(_ url: URL) -> Bool {
        isMultiPartVideoURL(url) || hasOuterCollectionContext(url)
    }

    static func isMultiPartVideoURL(_ url: URL) -> Bool {
        isBilibili(url) && url.path.lowercased().contains("/video/") &&
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name.lowercased() == "p" }) == true
    }

    static func hasOuterCollectionContext(_ url: URL) -> Bool {
        guard isBilibili(url) else { return false }
        let value = url.absoluteString.lowercased()
        let collectionMarkers = [
            "/list/",
            "/medialist/",
            "/channel/collectiondetail",
            "/channel/seriesdetail",
            "/lists/",
            "/favlist",
            "/bangumi/play/ss",
            "/cheese/play/ss",
            "/video?tid=",
            "/upload/video"
        ]
        if collectionMarkers.contains(where: { value.contains($0) }) {
            return true
        }

        let collectionQueryNames: Set<String> = [
            "collection_id",
            "fid",
            "list_id",
            "medialist_id",
            "mlid",
            "playlist_id",
            "season_id",
            "series_id",
            "sid"
        ]
        let collectionQueryValueMarkers = [
            "collection",
            "medialist",
            "playlist",
            "series",
            "ugc_season",
            "videopod.sections"
        ]
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.contains { item in
            let name = item.name.lowercased()
            let itemValue = item.value?.lowercased() ?? ""
            return collectionQueryNames.contains(name) ||
                (name == "spm_id_from" && collectionQueryValueMarkers.contains(where: itemValue.contains))
        }
    }

    static func isVideoPage(_ url: URL) -> Bool {
        url.path.lowercased().contains("/video/") && bvid(from: url) != nil
    }

    static func bvid(from url: URL) -> String? {
        guard isBilibili(url) else { return nil }
        guard let expression = try? NSRegularExpression(
            pattern: #"BV[0-9A-Za-z]+"#,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: url.path,
            range: NSRange(url.path.startIndex..<url.path.endIndex, in: url.path)
        ),
        let range = Range(match.range, in: url.path) else {
            return nil
        }
        return String(url.path[range])
    }
}

enum ThumbnailRequestPolicy {
    static func referer(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        if host == "qpic.cn" || host.hasSuffix(".qpic.cn") || host == "finder.video.qq.com" {
            return "https://channels.weixin.qq.com/"
        }
        if ["hdslb.com", "bilibili.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return "https://www.bilibili.com/"
        }
        if ["douyinpic.com", "douyincdn.com", "byteimg.com", "pstatp.com", "ibytedtos.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return "https://www.douyin.com/"
        }
        return nil
    }
}

enum DouyinErrorMessage {
    static func from(_ log: String) -> String {
        if let range = log.range(of: "BILIFETCH_DOUYIN:") {
            return String(log[range.upperBound...].split(separator: "\n").first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "暂时无法免登录读取这条抖音作品。请稍后重试或重新复制作品分享链接；私密、已删除或受限作品可能无法下载。"
    }
}

struct DownloadRequest {
    let url: URL
    let destination: URL
    let scope: DownloadScope
    let quality: VideoQuality
    let cookies: BrowserCookies
    let includeSubtitles: Bool
    let engine: DownloadEngine
    let outputTemplate: String?
    let cookieFileURL: URL?
    var weChatManifestURL: URL? = nil
}

enum DownloadCompletionEvaluator {
    static func succeeded(exitCode: Int32, hasCompletedVideo: Bool) -> Bool {
        // A process may exit cleanly even when post-processing did not create
        // the requested final file. Conversely, a verified final file is safe
        // to keep if only a trailing optional step returned non-zero.
        hasCompletedVideo
    }
}

enum DownloadOutputValidationPolicy {
    private static let supportedExtensions = Set(["mp4", "mkv", "webm", "flv", "mov", "m4v"])

    static func isPlausibleFinalVideoFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension),
              !lower.contains(".part") else { return false }
        return lower.range(
            of: #"\.f[0-9]+\.(mp4|mkv|webm|flv|mov|m4v)$"#,
            options: .regularExpression
        ) == nil
    }
}

enum DownloadRetryPolicy {
    static let maximumRetries = 3

    static func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt <= maximumRetries
    }
}

enum DownloadConcurrencyPolicy {
    static func clamped(_ value: Int) -> Int {
        max(1, min(value, 5))
    }
}

enum DownloadResumePolicy {
    static func shouldAutoResume(
        wasPausedForSystemSleep: Bool,
        isDownloading: Bool,
        isPaused: Bool
    ) -> Bool {
        wasPausedForSystemSleep && isDownloading && isPaused
    }
}

enum DownloadResidualFilePolicy {
    static func isResidualFile(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasSuffix(".aria2") || lower.hasSuffix(".part") ||
            lower.contains(".part.") || lower.contains(".part-")
    }

    static func belongsToCompletedFile(
        residualFileName: String,
        completedFileName: String
    ) -> Bool {
        guard isResidualFile(residualFileName) else { return false }
        let residual = residualFileName.lowercased()
        let completed = completedFileName.lowercased()
        let completedStem = URL(fileURLWithPath: completedFileName)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        return residual.hasPrefix(completed + ".") ||
            residual.hasPrefix(completedStem + ".")
    }
}

enum FilenameSanitizer {
    static func component(_ value: String, fallback: String = "未命名") -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?*\"<>|")
            .union(.controlCharacters)
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }
        let collapsed = scalars.joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let result = String(collapsed.prefix(90))
        return result.isEmpty ? fallback : result
    }

    static func collectionOutputTemplate(index: Int, total: Int, title: String) -> String {
        let width = max(2, String(max(total, 1)).count)
        let number = String(format: "%0\(width)d", index)
        let safeTitle = component(title).replacingOccurrences(of: "%", with: "%%")
        return "[\(number)] \(safeTitle) [%(id)s].%(ext)s"
    }
}

enum DownloadArgumentBuilder {
    static func cookieArguments(for url: URL, cookieFileURL: URL?, cookies: BrowserCookies) -> [String] {
        guard URLClassifier.isBilibili(url) else { return [] }
        if URLClassifier.isBilibili(url), let cookieFileURL {
            return ["--cookies", cookieFileURL.path]
        }
        return cookies == .none ? [] : ["--cookies-from-browser", cookies.rawValue]
    }

    static func pluginArguments(for url: URL) -> [String] {
        guard URLClassifier.isDouyin(url) else { return [] }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/yt-dlp-plugins", isDirectory: true)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp-plugins", isDirectory: true)
        let directory = [bundled, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("bilifetch/yt_dlp_plugins/extractor/douyin_share.py").path)
        }
        return directory.map { ["--no-plugin-dirs", "--plugin-dirs", $0.path, "--socket-timeout", "15", "--extractor-retries", "1"] } ?? []
    }

    static func arguments(
        for request: DownloadRequest,
        ffmpegPath: String?,
        aria2Path: String?,
        aria2RPC: Aria2RPCConfiguration? = nil
    ) -> [String] {
        var arguments = [
            "--ignore-config",
            "--no-colors",
            "--newline",
            "--continue",
            "--part",
            "--no-overwrites",
            "--retries", "8",
            "--fragment-retries", "8",
            "--concurrent-fragments", "4",
            "--paths", request.destination.path,
            "--output", request.outputTemplate ?? "%(playlist&{}/|)s%(playlist_index&{} - |)s%(title).180B [%(id)s].%(ext)s",
            // Keep this line ASCII-only. Pipe reads may split a multibyte title
            // between chunks; a title is not needed to identify the owning job.
            "--progress-template", "download:__PROGRESS__|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:__ITEM__|%(playlist_index|1)s|%(playlist_count|1)s|%(title)s",
            "--print", "after_move:__FILE__|%(filepath)s",
            "--progress",
            "--no-simulate"
        ]

        if request.engine == .aria2, let aria2Path {
            var downloaderArguments = "aria2c:--continue=true -x 8 -s 8 -k 1M --auto-file-renaming=false --allow-overwrite=false --all-proxy= --file-allocation=none --summary-interval=1 --show-console-readout=true --console-log-level=warn --enable-color=false"
            if let aria2RPC {
                downloaderArguments += " --enable-rpc=true --rpc-listen-all=false --rpc-listen-port=\(aria2RPC.port) --rpc-secret=\(aria2RPC.secret) --rpc-allow-origin-all=false"
            }
            arguments += [
                "--downloader", aria2Path,
                // yt-dlp may use the macOS system proxy to resolve metadata,
                // while aria2 downloads CDN media directly. The final aria2
                // option wins over the proxy value emitted by yt-dlp.
                "--downloader-args", downloaderArguments
            ]
        }

        if let ffmpegPath {
            arguments += [
                "--ffmpeg-location", ffmpegPath,
                "--format", request.quality.formatSelector,
                // The bundled minimal FFmpeg intentionally includes the MP4
                // muxer. Bilibili's HEVC/AVC video plus AAC audio can be
                // stream-copied into MP4; allowing MKV here made yt-dlp pick a
                // muxer that is not present in the bundled binary.
                "--merge-output-format", "mp4"
            ]
        } else {
            arguments += ["--format", "bv*+ba/b"]
        }

        arguments.append(request.scope.downloadsPlaylist(for: request.url) ? "--yes-playlist" : "--no-playlist")

        arguments += cookieArguments(for: request.url, cookieFileURL: request.cookieFileURL, cookies: request.cookies)
        arguments += pluginArguments(for: request.url)

        if request.includeSubtitles {
            arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "zh.*,danmaku"]
        }

        if URLClassifier.weChatCaptureID(request.url) != nil, let manifest = request.weChatManifestURL {
            arguments += ["--proxy", "", "--load-info-json", manifest.path]
        } else {
            arguments += ["--", request.url.absoluteString]
        }
        return arguments
    }
}
