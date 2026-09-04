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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              isAllowed(host: host) else {
            return nil
        }

        components.fragment = nil
        return components.url
    }

    static func isAllowed(host: String) -> Bool {
        host == "bilibili.com" ||
        host.hasSuffix(".bilibili.com") ||
        host == "b23.tv" ||
        host.hasSuffix(".b23.tv") ||
        host == "bilibili.tv" ||
        host.hasSuffix(".bilibili.tv")
    }

    static func looksLikeCollection(_ url: URL) -> Bool {
        isMultiPartVideoURL(url) || hasOuterCollectionContext(url)
    }

    static func isMultiPartVideoURL(_ url: URL) -> Bool {
        url.path.lowercased().contains("/video/") &&
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name.lowercased() == "p" }) == true
    }

    static func hasOuterCollectionContext(_ url: URL) -> Bool {
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
    static func arguments(
        for request: DownloadRequest,
        ffmpegPath: String?,
        aria2Path: String?
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
            "--progress-template", "download:__PROGRESS__|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.title)s",
            "--print", "before_dl:__ITEM__|%(playlist_index|1)s|%(playlist_count|1)s|%(title)s",
            "--print", "after_move:__FILE__|%(filepath)s",
            "--progress",
            "--no-simulate"
        ]

        if request.engine == .aria2, let aria2Path {
            arguments += [
                "--downloader", aria2Path,
                // yt-dlp may use the macOS system proxy to resolve metadata,
                // while aria2 downloads CDN media directly. The final aria2
                // option wins over the proxy value emitted by yt-dlp.
                "--downloader-args", "aria2c:--continue=true -x 8 -s 8 -k 1M --auto-file-renaming=false --allow-overwrite=false --all-proxy= --file-allocation=none --summary-interval=0 --show-console-readout=true --console-log-level=warn --enable-color=false"
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

        if let cookieFileURL = request.cookieFileURL {
            arguments += ["--cookies", cookieFileURL.path]
        } else if request.cookies != .none {
            arguments += ["--cookies-from-browser", request.cookies.rawValue]
        }

        if request.includeSubtitles {
            arguments += ["--write-subs", "--write-auto-subs", "--sub-langs", "zh.*,danmaku"]
        }

        arguments += ["--", request.url.absoluteString]
        return arguments
    }
}
