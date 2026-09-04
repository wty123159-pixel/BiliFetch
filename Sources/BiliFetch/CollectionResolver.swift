import Foundation

@MainActor
final class CollectionResolver {
    private let runner = ProcessRunner()
    private let metadataRunner = ProcessRunner()
    private var metadataOutputLines: [String] = []
    private var metadataDiagnosticLines: [String] = []
    private var outputLines: [String] = []
    private var diagnosticLines: [String] = []
    private var wasCancelled = false

    var isRunning: Bool { metadataRunner.isRunning || runner.isRunning }

    func resolve(
        sourceURL: URL,
        executable: URL,
        cookies: BrowserCookies,
        cookieFileURL: URL?,
        toolDirectory: URL?,
        onStatus: @escaping (String) -> Void,
        completion: @escaping (Result<CollectionPreview, Error>, String) -> Void
    ) throws {
        outputLines = []
        diagnosticLines = []
        metadataOutputLines = []
        metadataDiagnosticLines = []
        wasCancelled = false

        if let bvid = URLClassifier.bvid(from: sourceURL) {
            var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
            components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
            onStatus("正在读取视频分集信息…")

            let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
            try metadataRunner.start(
                executable: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: [
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--max-time", "15",
                    "--user-agent", userAgent,
                    "--referer", sourceURL.absoluteString,
                    "--header", "Accept: application/json",
                    "--", components.url!.absoluteString
                ],
                onLine: { [weak self] line, stream in
                    guard let self else { return }
                    switch stream {
                    case .standardOutput: self.metadataOutputLines.append(line)
                    case .standardError: self.metadataDiagnosticLines.append(line)
                    }
                },
                onFinish: { [weak self] exitCode in
                    guard let self, !self.wasCancelled else { return }
                    let metadataDiagnostics = self.metadataDiagnosticLines.joined(separator: "\n")
                    let data = self.metadataOutputLines.joined(separator: "\n").data(using: .utf8)
                    let preview = exitCode == 0
                        ? data.flatMap { try? BilibiliViewMetadataParser.parse(data: $0, sourceURL: sourceURL) }
                        : nil

                    if let preview, preview.items.count > 1 {
                        onStatus("已读取 \(preview.items.count) 个视频")
                        completion(.success(preview), metadataDiagnostics)
                        return
                    }

                    // The view API only describes the current BV when it has
                    // no UGC season metadata. Confirm a one-item response with
                    // yt-dlp before calling it final.
                    onStatus("正在确认是否包含完整合集…")
                    let mayUseSingleVideoFallback = !URLClassifier.hasOuterCollectionContext(sourceURL)
                    do {
                        try self.resolveWithYTDLP(
                            sourceURL: sourceURL,
                            executable: executable,
                            cookies: cookies,
                            cookieFileURL: cookieFileURL,
                            toolDirectory: toolDirectory,
                            fallbackPreview: mayUseSingleVideoFallback ? preview : nil,
                            requireMultipleItems: !mayUseSingleVideoFallback,
                            onStatus: onStatus,
                            completion: completion
                        )
                    } catch {
                        if mayUseSingleVideoFallback, let preview {
                            completion(.success(preview), metadataDiagnostics)
                        } else {
                            completion(.failure(error), metadataDiagnostics)
                        }
                    }
                }
            )
            return
        }

        try resolveWithYTDLP(
            sourceURL: sourceURL,
            executable: executable,
            cookies: cookies,
            cookieFileURL: cookieFileURL,
            toolDirectory: toolDirectory,
            onStatus: onStatus,
            completion: completion
        )
    }

    private func resolveWithYTDLP(
        sourceURL: URL,
        executable: URL,
        cookies: BrowserCookies,
        cookieFileURL: URL?,
        toolDirectory: URL?,
        fallbackPreview: CollectionPreview? = nil,
        requireMultipleItems: Bool = false,
        onStatus: @escaping (String) -> Void,
        completion: @escaping (Result<CollectionPreview, Error>, String) -> Void
    ) throws {
        outputLines = []
        diagnosticLines = []
        onStatus("正在通过 yt-dlp 读取合集信息…")

        var arguments = [
            "--ignore-config",
            "--no-colors",
            "--newline",
            "--skip-download",
            // Keep every playlist entry even when its available container or
            // codecs differ from neighboring episodes. Each entry is resolved
            // again immediately before its own download.
            "--ignore-no-formats-error",
            "--yes-playlist",
            "--no-warnings",
            "--print", "%(.{id,title,webpage_url,original_url,url,thumbnail,duration,playlist,playlist_title,playlist_index,playlist_count})j"
        ]
        if let cookieFileURL {
            arguments += ["--cookies", cookieFileURL.path]
        } else if cookies != .none {
            arguments += ["--cookies-from-browser", cookies.rawValue]
        }
        arguments += ["--", sourceURL.absoluteString]

        try runner.start(
            executable: executable,
            arguments: arguments,
            extraPathDirectories: [toolDirectory].compactMap { $0 },
            onLine: { [weak self] line, stream in
                guard let self else { return }
                switch stream {
                case .standardOutput:
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                        self.outputLines.append(line)
                        onStatus("已读取 \(self.outputLines.count) 个视频…")
                    }
                case .standardError:
                    self.diagnosticLines.append(line)
                }
            },
            onFinish: { [weak self] exitCode in
                guard let self else { return }
                let diagnostics = self.diagnosticLines.joined(separator: "\n")
                guard exitCode == 0 else {
                    if let fallbackPreview {
                        onStatus("未发现外层合集，已读取当前视频")
                        completion(.success(fallbackPreview), diagnostics)
                        return
                    }
                    let error = NSError(
                        domain: "BiliFetch.CollectionResolver",
                        code: Int(exitCode),
                        userInfo: [NSLocalizedDescriptionKey: self.friendlyError(from: diagnostics)]
                    )
                    completion(.failure(error), diagnostics)
                    return
                }

                do {
                    let preview = try CollectionMetadataParser.parse(lines: self.outputLines, sourceURL: sourceURL)
                    guard !requireMultipleItems || preview.items.count > 1 else {
                        throw NSError(
                            domain: "BiliFetch.CollectionResolver",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "链接带有合集信息，但只解析到当前视频，请稍后重试。"]
                        )
                    }
                    completion(.success(preview), diagnostics)
                } catch {
                    if let fallbackPreview {
                        onStatus("未发现外层合集，已读取当前视频")
                        completion(.success(fallbackPreview), diagnostics)
                    } else {
                        completion(.failure(error), diagnostics)
                    }
                }
            }
        )
    }

    func cancel() {
        wasCancelled = true
        metadataRunner.cancel()
        runner.cancel()
    }

    private func friendlyError(from log: String) -> String {
        let lower = log.lowercased()
        if lower.contains("412") || lower.contains("-352") {
            return "B站暂时拒绝了合集请求，请稍后重试或选择已登录的浏览器。"
        }
        if lower.contains("login required") || lower.contains("sign in") {
            return "该合集需要登录，请在高级选项中扫码登录 B 站，或选择已登录的浏览器。"
        }
        if lower.contains("unsupported url") {
            return "无法识别该合集链接。"
        }
        return "获取合集列表失败，请展开日志查看原因。"
    }
}
