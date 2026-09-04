import AppKit
import CryptoKit
import Foundation

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progressHandler: (Double) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var finished = false

    init(destination: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        progressHandler = progress
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: location, to: destination)
            finished = true
            completion(.success(destination))
        } catch {
            finished = true
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        finished = true
        completion(.failure(error))
    }
}

@MainActor
final class MacAppUpdater: ObservableObject {
    private static let defaultManifestURL = "https://github.com/wty123159-pixel/BiliFetch/releases/latest/download/update.json"

    enum Phase: Equatable {
        case idle
        case checking
        case available
        case downloading
        case ready
        case current
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: AppUpdateRelease?
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = ""

    private var downloadSession: URLSession?
    private var downloadDelegate: UpdateDownloadDelegate?
    private var stagedAppURL: URL?
    private let acceleratedDownloadRunner = ProcessRunner()

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var bundledManifestURLs: [URL] {
        var values: [String] = []
        if let url = Bundle.main.url(forResource: "update-channel", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values.append(contentsOf: object["manifestURLs"] as? [String] ?? [])
            if let legacy = object["manifestURL"] as? String { values.append(legacy) }
        }
        values.append(Self.defaultManifestURL)
        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    func check(silent: Bool = false) {
        guard phase != .checking, phase != .downloading else { return }
        let sources = bundledManifestURLs
        guard !sources.isEmpty else {
            if !silent { fail(AppUpdateError.notConfigured) }
            return
        }
        phase = .checking
        statusText = "正在检查更新…"
        requestManifest(from: sources, index: 0, silent: silent)
    }

    private func requestManifest(from sources: [URL], index: Int, silent: Bool) {
        let url = sources[index]
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BiliFetch-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    if let error { throw AppUpdateError.downloadFailed(error.localizedDescription) }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                        throw AppUpdateError.downloadFailed("更新服务器没有返回有效数据。")
                    }
                    let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
                    let release = try manifest.macOSRelease()
                    if try AppVersion.compare(release.version, self.currentVersion) == .orderedDescending {
                        self.release = release
                        self.phase = .available
                        self.statusText = "发现新版本 v\(release.version)"
                    } else {
                        self.release = nil
                        self.phase = .current
                        self.statusText = "当前 v\(self.currentVersion) 已是最新版本。"
                    }
                } catch {
                    let next = index + 1
                    if next < sources.count {
                        self.requestManifest(from: sources, index: next, silent: silent)
                    } else if silent {
                        self.phase = .idle
                        self.statusText = ""
                    } else {
                        self.fail(error)
                    }
                }
            }
        }.resume()
    }

    func download() {
        guard let release else { return }
        let updateRoot = Self.updateRoot.appendingPathComponent(release.version, isDirectory: true)
        let archive = updateRoot.appendingPathComponent("BiliFetch-update.zip")
        do {
            try? FileManager.default.removeItem(at: updateRoot)
            try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        } catch {
            fail(error)
            return
        }

        phase = .downloading
        progress = 0
        statusText = "正在启动多连接更新下载…"
        if startAcceleratedDownload(to: archive, release: release) { return }
        startStandardDownload(to: archive, release: release)
    }

    private func startAcceleratedDownload(to archive: URL, release: AppUpdateRelease) -> Bool {
        guard let aria2 = BackendLocator.locateExecutable(named: "aria2c") else { return false }
        let arguments = [
            "--allow-overwrite=true", "--auto-file-renaming=false", "--continue=true",
            "--file-allocation=none", "--max-connection-per-server=8", "--split=8",
            "--min-split-size=1M", "--max-tries=3", "--retry-wait=2",
            "--connect-timeout=20", "--timeout=30", "--summary-interval=1",
            "--show-console-readout=true", "--console-log-level=warn", "--enable-color=false",
            "--user-agent=BiliFetch-macOS/\(currentVersion)",
            "--dir=\(archive.deletingLastPathComponent().path)", "--out=\(archive.lastPathComponent)",
            "--", release.url.absoluteString
        ]
        do {
            try acceleratedDownloadRunner.start(
                executable: aria2,
                arguments: arguments,
                onLine: { [weak self] line, _ in
                    guard let self, let transfer = UpdateProgressParser.aria2(line) else { return }
                    self.progress = transfer.fraction
                    self.statusText = transfer.speed.isEmpty
                        ? "正在多连接下载更新包…"
                        : "正在多连接下载更新包 · \(transfer.speed)"
                },
                onFinish: { [weak self] exitCode in
                    guard let self else { return }
                    if exitCode == 0, FileManager.default.fileExists(atPath: archive.path) {
                        self.verifyAndExtract(archive, release: release)
                    } else {
                        try? FileManager.default.removeItem(at: archive)
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: archive.path + ".aria2"))
                        self.statusText = "多连接下载不可用，正在切换标准下载…"
                        self.startStandardDownload(to: archive, release: release)
                    }
                }
            )
            return true
        } catch {
            return false
        }
    }

    private func startStandardDownload(to archive: URL, release: AppUpdateRelease) {
        statusText = "正在使用标准方式下载更新包…"
        let delegate = UpdateDownloadDelegate(
            destination: archive,
            progress: { [weak self] value in
                DispatchQueue.main.async { self?.progress = value }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let archive): self.verifyAndExtract(archive, release: release)
                    case .failure(let error): self.fail(AppUpdateError.downloadFailed(error.localizedDescription))
                    }
                }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: release.url).resume()
    }

    func install() {
        guard let stagedAppURL else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension.lowercased() == "app" else {
            fail(AppUpdateError.developmentBuild)
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            fail(AppUpdateError.appLocationNotWritable)
            return
        }

        do {
            let helper = Self.updateRoot.appendingPathComponent("install-update-\(UUID().uuidString).zsh")
            let log = Self.updateRoot.appendingPathComponent("update-install.log")
            let script = """
            #!/bin/zsh
            set -u
            source_app="$1"
            target_app="$2"
            running_pid="$3"
            log_file="$4"
            while /bin/kill -0 "$running_pid" 2>/dev/null; do /bin/sleep 0.2; done
            if /usr/bin/ditto "$source_app" "$target_app" >>"$log_file" 2>&1; then
                /usr/bin/open "$target_app"
                print "Update installed successfully." >>"$log_file"
            else
                print "Update installation failed." >>"$log_file"
            fi
            /bin/rm -- "$0"
            """
            try FileManager.default.createDirectory(at: Self.updateRoot, withIntermediateDirectories: true)
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, stagedAppURL.path, target.path, String(ProcessInfo.processInfo.processIdentifier), log.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            fail(error)
        }
    }

    func dismiss() {
        if phase != .downloading { phase = .idle }
    }

    private func verifyAndExtract(_ archive: URL, release: AppUpdateRelease) {
        phase = .downloading
        statusText = "正在校验并解压更新包…"
        let extracted = archive.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let digest = try Self.sha256(of: archive)
                guard digest == release.sha256 else {
                    try? FileManager.default.removeItem(at: archive)
                    throw AppUpdateError.checksumMismatch
                }
                try? FileManager.default.removeItem(at: extracted)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", archive.path, extracted.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0, let appURL = Self.findApp(in: extracted) else {
                    throw AppUpdateError.archiveInvalid
                }
                DispatchQueue.main.async {
                    self?.stagedAppURL = appURL
                    self?.progress = 1
                    self?.phase = .ready
                    self?.statusText = "更新包已通过校验，可以退出并升级。"
                }
            } catch {
                DispatchQueue.main.async { self?.fail(error) }
            }
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        statusText = error.localizedDescription
    }

    private static var updateRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BiliFetch/Updates", isDirectory: true)
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func findApp(in root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" && url.lastPathComponent == "BiliFetch.app" { return url }
        }
        return nil
    }
}
