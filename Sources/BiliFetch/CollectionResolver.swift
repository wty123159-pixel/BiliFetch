import Foundation

@MainActor
final class CollectionResolver {
    private let runner = ProcessRunner()
    private var metadataTask: URLSessionDataTask?
    private var outputLines: [String] = []
    private var diagnosticLines: [String] = []
    private var wasCancelled = false

    var isRunning: Bool { metadataTask != nil || runner.isRunning }

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
        wasCancelled = false

        if let bvid = URLClassifier.bvid(from: sourceURL) {
            var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
            components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 15
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(sourceURL.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            onStatus("正在读取视频分集信息…")

            metadataTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.metadataTask = nil
                    guard !self.wasCancelled else { return }

                    if let data,
                       let preview = try? BilibiliViewMetadataParser.parse(data: data, sourceURL: sourceURL) {
                        onStatus("已读取 \(preview.items.count) 个视频")
                        completion(.success(preview), "")
                        return
                    }

                    do {
                        try self.resolveWithYTDLP(
                            sourceURL: sourceURL,
                            executable: executable,
                            cookies: cookies,
                            cookieFileURL: cookieFileURL,
                            toolDirectory: toolDirectory,
                            onStatus: onStatus,
                            completion: completion
                        )
                    } catch {
                        completion(.failure(error), self.diagnosticLines.joined(separator: "\n"))
                    }
                }
            }
            metadataTask?.resume()
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
                    let error = NSError(
                        domain: "BiliFetch.CollectionResolver",
                        code: Int(exitCode),
                        userInfo: [NSLocalizedDescriptionKey: self.friendlyError(from: diagnostics)]
                    )
                    completion(.failure(error), diagnostics)
                    return
                }

                do {
                    completion(.success(try CollectionMetadataParser.parse(lines: self.outputLines, sourceURL: sourceURL)), diagnostics)
                } catch {
                    completion(.failure(error), diagnostics)
                }
            }
        )
    }

    func cancel() {
        wasCancelled = true
        metadataTask?.cancel()
        metadataTask = nil
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
