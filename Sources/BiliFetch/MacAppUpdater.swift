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
    private var attemptedFullFallback = false
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
                    let release = try manifest.macOSRelease(currentVersion: self.currentVersion)
                    if try AppVersion.compare(release.version, self.currentVersion) == .orderedDescending {
                        self.release = release
                        self.phase = .available
                        self.statusText = release.delta == nil
                            ? "发现新版本 v\(release.version)"
                            : "发现新版本 v\(release.version) · 可用小体积增量更新"
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
        attemptedFullFallback = false
        stagedAppURL = nil
        beginDownload(release.preferredAsset, release: release)
    }

    private func beginDownload(_ asset: AppUpdateAsset, release: AppUpdateRelease) {
        let updateRoot = Self.updateRoot.appendingPathComponent(release.version, isDirectory: true)
        let archiveName = asset.kind == .delta ? "BiliFetch-delta-update.zip" : "BiliFetch-full-update.zip"
        let archive = updateRoot.appendingPathComponent(archiveName)
        do {
            downloadSession?.invalidateAndCancel()
            downloadSession = nil
            downloadDelegate = nil
            try? FileManager.default.removeItem(at: updateRoot)
            try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        } catch {
            fail(error)
            return
        }

        phase = .downloading
        progress = 0
        statusText = asset.kind == .delta ? "正在启动增量更新下载…" : "正在启动完整更新下载…"
        if startAcceleratedDownload(to: archive, release: release, asset: asset) { return }
        startStandardDownload(to: archive, release: release, asset: asset)
    }

    private func startAcceleratedDownload(to archive: URL, release: AppUpdateRelease, asset: AppUpdateAsset) -> Bool {
        guard let aria2 = BackendLocator.locateExecutable(named: "aria2c") else { return false }
        let arguments = [
            "--allow-overwrite=true", "--auto-file-renaming=false", "--continue=true",
            "--file-allocation=none", "--max-connection-per-server=8", "--split=8",
            "--min-split-size=1M", "--max-tries=3", "--retry-wait=2",
            "--connect-timeout=20", "--timeout=30", "--summary-interval=1",
            "--show-console-readout=true", "--console-log-level=warn", "--enable-color=false",
            "--user-agent=BiliFetch-macOS/\(currentVersion)",
            "--dir=\(archive.deletingLastPathComponent().path)", "--out=\(archive.lastPathComponent)",
            "--", asset.url.absoluteString
        ]
        do {
            try acceleratedDownloadRunner.start(
                executable: aria2,
                arguments: arguments,
                onLine: { [weak self] line, _ in
                    guard let self, let transfer = UpdateProgressParser.aria2(line) else { return }
                    self.progress = transfer.fraction
                    let label = asset.kind == .delta ? "正在下载增量更新" : "正在下载完整更新"
                    self.statusText = transfer.speed.isEmpty ? "\(label)…" : "\(label) · \(transfer.speed)"
                },
                onFinish: { [weak self] exitCode in
                    guard let self else { return }
                    if exitCode == 0, FileManager.default.fileExists(atPath: archive.path) {
                        self.verifyAndStage(archive, release: release, asset: asset)
                    } else {
                        try? FileManager.default.removeItem(at: archive)
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: archive.path + ".aria2"))
                        self.statusText = "多连接下载不可用，正在切换标准下载…"
                        self.startStandardDownload(to: archive, release: release, asset: asset)
                    }
                }
            )
            return true
        } catch {
            return false
        }
    }

    private func startStandardDownload(to archive: URL, release: AppUpdateRelease, asset: AppUpdateAsset) {
        statusText = asset.kind == .delta ? "正在使用标准方式下载增量更新…" : "正在使用标准方式下载完整更新…"
        let delegate = UpdateDownloadDelegate(
            destination: archive,
            progress: { [weak self] value in
                DispatchQueue.main.async { self?.progress = value }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let archive): self.verifyAndStage(archive, release: release, asset: asset)
                    case .failure(let error): self.handleAssetFailure(error, release: release, asset: asset)
                    }
                }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: asset.url).resume()
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
            backup_app="${target_app}.update-backup"
            while /bin/kill -0 "$running_pid" 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf -- "$backup_app"
            if /bin/mv -- "$target_app" "$backup_app" >>"$log_file" 2>&1 && \
               /usr/bin/ditto "$source_app" "$target_app" >>"$log_file" 2>&1 && \
               /usr/bin/open "$target_app" >>"$log_file" 2>&1; then
                /bin/rm -rf -- "$backup_app"
                print "Update installed successfully." >>"$log_file"
            else
                print "Update installation failed." >>"$log_file"
                /bin/rm -rf -- "$target_app"
                if [[ -d "$backup_app" ]]; then
                    /bin/mv -- "$backup_app" "$target_app"
                    /usr/bin/open "$target_app"
                fi
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

    private func verifyAndStage(_ archive: URL, release: AppUpdateRelease, asset: AppUpdateAsset) {
        phase = .downloading
        statusText = asset.kind == .delta ? "正在校验并应用增量更新…" : "正在校验并解压完整更新…"
        let extracted = archive.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        let currentAppURL = Bundle.main.bundleURL
        let currentVersion = self.currentVersion
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let digest = try Self.sha256(of: archive)
                guard digest == asset.sha256 else {
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
                guard process.terminationStatus == 0 else { throw AppUpdateError.archiveInvalid }
                let appURL: URL
                if asset.kind == .delta {
                    appURL = try Self.stageDelta(
                        extracted: extracted,
                        currentApp: currentAppURL,
                        currentVersion: currentVersion,
                        release: release
                    )
                } else {
                    guard let found = Self.findApp(in: extracted) else { throw AppUpdateError.archiveInvalid }
                    try Self.validateStagedApp(found, expectedVersion: release.version)
                    appURL = found
                }
                DispatchQueue.main.async {
                    self?.stagedAppURL = appURL
                    self?.progress = 1
                    self?.phase = .ready
                    self?.statusText = "更新包已通过校验，可以退出并升级。"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.handleAssetFailure(error, release: release, asset: asset)
                }
            }
        }
    }

    private func handleAssetFailure(_ error: Error, release: AppUpdateRelease, asset: AppUpdateAsset) {
        if asset.kind == .delta, !attemptedFullFallback {
            attemptedFullFallback = true
            statusText = "增量更新不可用，正在改用完整更新包…"
            beginDownload(release.fullAsset, release: release)
            return
        }
        fail(error)
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

    private nonisolated static func stageDelta(
        extracted: URL,
        currentApp: URL,
        currentVersion: String,
        release: AppUpdateRelease
    ) throws -> URL {
        guard currentApp.pathExtension.lowercased() == "app" else { throw AppUpdateError.developmentBuild }
        guard let planURL = findFile(named: "delta.json", in: extracted) else {
            throw AppUpdateError.invalidDelta("增量包缺少 delta.json。")
        }
        let plan = try JSONDecoder().decode(AppDeltaPlan.self, from: Data(contentsOf: planURL))
        try plan.validate(currentVersion: currentVersion, targetVersion: release.version)
        let payload = planURL.deletingLastPathComponent().appendingPathComponent("payload", isDirectory: true)
        let staged = extracted.deletingLastPathComponent()
            .appendingPathComponent("staged", isDirectory: true)
            .appendingPathComponent("BiliFetch.app", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [currentApp.path, staged.path])

        for relativePath in plan.deletePaths {
            let target = try safeChild(relativePath, under: staged)
            try? FileManager.default.removeItem(at: target)
        }
        for file in plan.files {
            let target = try safeChild(file.path, under: staged)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let patch = file.patch {
                let patchData = try safeChild(patch.source, under: payload)
                try applyBinaryPatch(patch, dataURL: patchData, baseURL: target)
            } else {
                let source = try safeChild(file.path, under: payload)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw AppUpdateError.invalidDelta("增量包缺少文件：\(file.path)")
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
            if let mode = file.mode {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
                  try sha256(of: target) == file.sha256.lowercased() else {
                throw AppUpdateError.invalidDelta("增量文件校验失败：\(file.path)")
            }
        }

        try validateStagedApp(staged, expectedVersion: release.version)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        return staged
    }

    private nonisolated static func applyBinaryPatch(
        _ patch: AppDeltaPlan.FileEntry.BinaryPatch,
        dataURL: URL,
        baseURL: URL
    ) throws {
        let manager = FileManager.default
        let baseValues = try baseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let dataValues = try dataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let baseAttributes = try manager.attributesOfItem(atPath: baseURL.path)
        let dataAttributes = try manager.attributesOfItem(atPath: dataURL.path)
        guard baseValues.isRegularFile == true, baseValues.isSymbolicLink != true,
              dataValues.isRegularFile == true, dataValues.isSymbolicLink != true,
              (baseAttributes[.size] as? NSNumber)?.int64Value == patch.baseSize,
              (dataAttributes[.size] as? NSNumber)?.int64Value == patch.dataSize,
              try sha256(of: baseURL) == patch.baseSha256.lowercased(),
              try sha256(of: dataURL) == patch.dataSha256.lowercased() else {
            throw AppUpdateError.invalidDelta("二进制补丁的基础文件或数据校验失败。")
        }
        let temporary = baseURL.deletingLastPathComponent()
            .appendingPathComponent(".bilifetch-patch-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw AppUpdateError.invalidDelta("无法创建二进制补丁临时文件。")
        }
        defer { try? manager.removeItem(at: temporary) }
        let baseHandle = try FileHandle(forReadingFrom: baseURL)
        let dataHandle = try FileHandle(forReadingFrom: dataURL)
        let outputHandle = try FileHandle(forWritingTo: temporary)
        defer {
            try? baseHandle.close()
            try? dataHandle.close()
            try? outputHandle.close()
        }
        for operation in patch.operations {
            let input = operation.type == "copy" ? baseHandle : dataHandle
            try input.seek(toOffset: UInt64(operation.offset))
            var remaining = operation.length
            while remaining > 0 {
                let count = Int(min(remaining, 1024 * 1024))
                let chunk = try input.read(upToCount: count) ?? Data()
                guard chunk.count == count else {
                    throw AppUpdateError.invalidDelta("二进制补丁数据不完整。")
                }
                try outputHandle.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        try outputHandle.synchronize()
        try outputHandle.close()
        try? manager.removeItem(at: baseURL)
        try manager.moveItem(at: temporary, to: baseURL)
    }

    private nonisolated static func validateStagedApp(_ app: URL, expectedVersion: String) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let version = info["CFBundleShortVersionString"] as? String,
              try AppVersion.compare(version, expectedVersion) == .orderedSame,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/BiliFetch").path) else {
            throw AppUpdateError.archiveInvalid
        }
    }

    private nonisolated static func safeChild(_ relativePath: String, under root: URL) throws -> URL {
        guard AppDeltaPlan.isSafeRelativePath(relativePath) else {
            throw AppUpdateError.invalidDelta("增量包包含不安全的文件路径。")
        }
        let normalizedRoot = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(normalizedRoot + "/") else {
            throw AppUpdateError.invalidDelta("增量包文件超出应用目录。")
        }
        return candidate
    }

    private nonisolated static func findFile(named name: String, in root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidDelta("无法安全地准备增量更新。")
        }
    }
}
