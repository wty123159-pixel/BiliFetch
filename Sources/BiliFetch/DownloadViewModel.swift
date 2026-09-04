import AppKit
import Foundation
import Network

private final class DownloadJobDelegate: DownloaderServiceDelegate {
    private let lineHandler: (String) -> Void
    private let finishHandler: (Int32) -> Void

    init(onLine: @escaping (String) -> Void, onFinish: @escaping (Int32) -> Void) {
        lineHandler = onLine
        finishHandler = onFinish
    }

    func downloaderDidReceive(line: String) {
        lineHandler(line)
    }

    func downloaderDidFinish(exitCode: Int32) {
        finishHandler(exitCode)
    }
}

@MainActor
final class DownloadViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case analyzing
        case downloading
        case success
        case failed(String)
        case cancelled
    }

    private enum ActiveDownload {
        case single
        case collection(itemID: String)
    }

    private struct DownloadJob {
        let kind: ActiveDownload
        let request: DownloadRequest
        let startedAt: Date
        let attempt: Int
        let service: DownloaderService
        let delegate: DownloadJobDelegate
        var latestFile: URL?
        var logLines: [String]
    }

    private struct ResumeSnapshot: Codable {
        let sourceURL: String
        let destinationPath: String
        let scope: String
        let quality: String
        let cookies: String
        let includeSubtitles: Bool
        let engine: String
        let concurrency: Int
        let selectedIndexes: [Int]
        let remainingIndexes: [Int]
    }

    @Published var link = ""
    @Published var destination: URL
    @Published var scope: DownloadScope
    @Published var quality: VideoQuality
    @Published var cookies: BrowserCookies
    @Published var includeSubtitles: Bool
    @Published var engine: DownloadEngine
    @Published var downloadConcurrency: Int
    @Published var state: State = .idle
    @Published var progress = 0.0
    @Published var statusText = "粘贴 B 站链接后即可下载"
    @Published var detailText = ""
    @Published var currentItem = ""
    @Published var itemPosition = ""
    @Published var latestFile: URL?
    @Published var backend = BackendLocator.locate()
    @Published var collectionTitle = ""
    @Published var collectionItems: [CollectionItem] = []
    @Published var isBilibiliLoggedIn = false
    @Published var bilibiliLoginStatus = "未登录"
    @Published var isPaused = false
    @Published var requiresReanalysisAfterPermanentFailure = false

    private var activeCollectionResolver: CollectionResolver?
    private var activeAnalysisID: UUID?
    private let authService = BilibiliAuthService()
    private let defaults = UserDefaults.standard
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "BiliFetch.NetworkMonitor")
    private let resumeSnapshotKey = "unfinishedDownloadSnapshot"
    private var collectionSourceURL: String?
    private var pendingItemIDs: [String] = []
    private var batchItemIDs: Set<String> = []
    private var activeJobs: [String: DownloadJob] = [:]
    private var pauseRequestedJobIDs: Set<String> = []
    private var completedOutputFiles: Set<URL> = []
    private var permanentFailureCount = 0
    private var pausedSingleJob: (request: DownloadRequest, attempt: Int)?
    private var wasCancelled = false
    private var automaticAnalysisTask: Task<Void, Never>?
    private var automaticDetectionURL: String?
    private var automaticDetectedCollection: Bool?
    private var pendingResumeSnapshot: ResumeSnapshot?
    private var automaticResumeTask: Task<Void, Never>?
    private var wakeResumeTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var powerActivity: NSObjectProtocol?
    private var pausedForSystemSleep = false
    private var networkIsAvailable = true
    private var logLines: [String] = []

    init() {
        let defaultDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BiliFetch", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/BiliFetch")

        if let savedPath = defaults.string(forKey: "downloadDirectory") {
            destination = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            destination = defaultDestination
        }
        // Begin every launch with the safe preview-first flow. A range
        // override remains available for the current session.
        scope = .automatic
        // Every launch starts at the highest quality currently available to
        // the active account (or to a guest). The user can still lower it for
        // the current session.
        quality = .best
        cookies = BrowserCookies(rawValue: defaults.string(forKey: "browserCookies") ?? "") ?? .none
        includeSubtitles = defaults.bool(forKey: "includeSubtitles")
        engine = DownloadEngine(rawValue: defaults.string(forKey: "downloadEngine") ?? "") ?? .aria2
        let savedConcurrency = defaults.integer(forKey: "downloadConcurrency")
        downloadConcurrency = (1...5).contains(savedConcurrency) ? savedConcurrency : 3
        refreshBilibiliLoginStatus()
        installPowerAndNetworkObservers()
        restoreUnfinishedDownloadIfNeeded()
    }

    var isDownloading: Bool { state == .downloading }
    var isAnalyzing: Bool { state == .analyzing }
    var isBusy: Bool { isDownloading || isAnalyzing }
    var usesIndeterminateDownloadProgress: Bool {
        isDownloading && engine == .aria2 && backend.aria2c != nil
    }

    var wantsCollection: Bool {
        guard let url = URLClassifier.validatedURL(from: link) else { return false }
        switch scope {
        case .current:
            return false
        case .collection:
            return true
        case .automatic:
            if automaticDetectionURL == url.absoluteString,
               let automaticDetectedCollection {
                return automaticDetectedCollection
            }
            return URLClassifier.looksLikeCollection(url)
        }
    }

    private var needsAutomaticScopeDetection: Bool {
        guard scope == .automatic,
              let url = URLClassifier.validatedURL(from: link) else { return false }
        return automaticDetectionURL != url.absoluteString
    }

    var hasCurrentCollectionPreview: Bool {
        guard let url = URLClassifier.validatedURL(from: link) else { return false }
        return collectionSourceURL == url.absoluteString && !collectionItems.isEmpty
    }

    var selectedItemCount: Int {
        collectionItems.filter(\.isSelected).count
    }

    var completedItemCount: Int {
        collectionItems.filter { $0.status == .completed }.count
    }

    var remainingSelectedItemCount: Int {
        collectionItems.filter { $0.isSelected && $0.status != .completed }.count
    }

    var canAnalyzeCollection: Bool {
        !isBusy && !hasCurrentCollectionPreview &&
            URLClassifier.validatedURL(from: link) != nil && backend.ytDLP != nil
    }

    var canStart: Bool {
        guard !isBusy,
              URLClassifier.validatedURL(from: link) != nil,
              backend.hasFullQualitySupport,
              !requiresReanalysisAfterPermanentFailure,
              hasCurrentCollectionPreview else { return false }
        return remainingSelectedItemCount > 0
    }

    var backendSummary: String {
        if backend.hasFullQualitySupport {
            return backend.hasAccelerationSupport
                ? "下载组件已就绪，支持 aria2 多连接加速"
                : "下载组件已就绪；未发现 aria2，将使用标准模式"
        }
        if backend.canDownload {
            return "可下载；安装 FFmpeg 后可合并最高画质"
        }
        return "首次使用需先准备下载组件"
    }

    var resolvedScopeSummary: String {
        guard URLClassifier.validatedURL(from: link) != nil else { return "等待有效链接" }
        if isAnalyzing || !hasCurrentCollectionPreview {
            return "正在解析链接与分集信息…"
        }
        if hasCurrentCollectionPreview {
            return collectionItems.count == 1
                ? "视频信息已就绪"
                : "已获取 \(collectionItems.count) 个视频，选中 \(selectedItemCount) 个"
        }
        if wantsCollection {
            return "将先获取合集列表、标题和封面供你预览"
        }
        return "将仅下载当前视频"
    }

    func refreshBackend() {
        backend = BackendLocator.locate()
    }

    func linkDidChange() {
        guard !isDownloading else { return }
        if isAnalyzing {
            cancelActiveCollectionAnalysis()
            state = .idle
        }
        automaticResumeTask?.cancel()
        requiresReanalysisAfterPermanentFailure = false
        automaticAnalysisTask?.cancel()
        let normalized = URLClassifier.validatedURL(from: link)?.absoluteString
        if let saved = savedResumeSnapshot(), saved.sourceURL != normalized {
            clearResumeSnapshot()
        }
        if automaticDetectionURL != normalized {
            automaticDetectionURL = nil
            automaticDetectedCollection = nil
        }
        if collectionSourceURL != normalized {
            clearCollectionPreview()
        }
        if state != .idle {
            state = .idle
            statusText = "链接已更新"
        }
        scheduleAutomaticCollectionAnalysis()
    }

    func scopeDidChange() {
        guard !isDownloading else { return }
        if isAnalyzing {
            cancelActiveCollectionAnalysis()
            state = .idle
        }
        automaticResumeTask?.cancel()
        if savedResumeSnapshot() != nil { clearResumeSnapshot() }
        automaticAnalysisTask?.cancel()
        if state != .idle {
            state = .idle
            statusText = "下载范围已更新"
        }
        clearCollectionPreview()
        scheduleAutomaticCollectionAnalysis()
    }

    func pasteLink() {
        if let value = NSPasteboard.general.string(forType: .string) {
            let pastedLink = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if pastedLink == link {
                linkDidChange()
            } else {
                link = pastedLink
            }
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择下载位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if panel.runModal() == .OK, let selected = panel.url {
            destination = selected
            defaults.set(selected.path, forKey: "downloadDirectory")
        }
    }

    func prepareTools() {
        guard let script = BackendLocator.bundledSetupScript else {
            state = .failed("未找到组件准备脚本，请从完整 App 包重新打开。")
            return
        }
        NSWorkspace.shared.open(script)
    }

    func refreshBilibiliLoginStatus() {
        authService.refreshStatus { [weak self] loggedIn in
            guard let self else { return }
            self.isBilibiliLoggedIn = loggedIn
            self.bilibiliLoginStatus = loggedIn ? "已登录，将使用账号画质权限" : "未登录，将使用游客最高画质"
        }
    }

    func generateBilibiliQRCode(completion: @escaping (Result<BilibiliQRCode, Error>) -> Void) {
        authService.generateQRCode(completion: completion)
    }

    func pollBilibiliQRCode(
        key: String,
        completion: @escaping (Result<BilibiliQRCodePollResult, Error>) -> Void
    ) {
        authService.pollQRCode(key: key) { [weak self] result in
            guard let self else { return }
            if case .success(.authenticated) = result {
                self.isBilibiliLoggedIn = true
                self.bilibiliLoginStatus = "已登录，将使用账号画质权限"
                self.quality = .best
            }
            completion(result)
        }
    }

    func logOutBilibili(completion: @escaping () -> Void) {
        authService.logOut { [weak self] in
            guard let self else { return }
            self.isBilibiliLoggedIn = false
            self.bilibiliLoginStatus = "未登录，将使用游客最高画质"
            self.quality = .best
            completion()
        }
    }

    func analyzeCollection() {
        resolveCollection(isAutomaticProbe: scope == .automatic)
    }

    private func resolveCollection(isAutomaticProbe: Bool) {
        guard let url = URLClassifier.validatedURL(from: link) else {
            state = .failed("请输入有效链接后再进行解析。")
            return
        }
        guard let ytDLP = backend.ytDLP else {
            state = .failed("尚未安装 yt-dlp，请先准备下载组件。")
            return
        }

        automaticAnalysisTask?.cancel()
        automaticAnalysisTask = nil
        activeCollectionResolver?.cancel()
        let resolver = CollectionResolver()
        let analysisID = UUID()
        activeCollectionResolver = resolver
        activeAnalysisID = analysisID
        savePreferences()
        state = .analyzing
        progress = 0
        currentItem = ""
        itemPosition = ""
        detailText = ""
        logLines = []
        collectionTitle = ""
        collectionItems = []
        collectionSourceURL = nil
        statusText = isAutomaticProbe ? "正在识别单视频或合集…" : "正在读取合集信息…"
        let analysisURL = url.absoluteString

        do {
            try resolver.resolve(
                sourceURL: url,
                executable: ytDLP,
                cookies: cookies,
                cookieFileURL: activeCookieFileURL,
                toolDirectory: backend.ffmpeg?.deletingLastPathComponent(),
                onStatus: { [weak self] status in
                    guard let self,
                          self.activeAnalysisID == analysisID,
                          URLClassifier.validatedURL(from: self.link)?.absoluteString == analysisURL else { return }
                    self.statusText = status
                },
                completion: { [weak self] result, diagnostics in
                    guard let self,
                          self.activeAnalysisID == analysisID,
                          URLClassifier.validatedURL(from: self.link)?.absoluteString == analysisURL else { return }
                    self.activeAnalysisID = nil
                    self.activeCollectionResolver = nil
                    if !diagnostics.isEmpty {
                        self.logLines = diagnostics.components(separatedBy: .newlines)
                        self.detailText = diagnostics
                    }
                    switch result {
                    case .success(let preview):
                        if isAutomaticProbe,
                           self.scope == .automatic,
                           URLClassifier.validatedURL(from: self.link)?.absoluteString == analysisURL {
                            self.automaticDetectionURL = analysisURL
                            self.automaticDetectedCollection = preview.items.count > 1
                        }
                        let displayedPreview: CollectionPreview
                        if self.scope == .current {
                            let requestedPage = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                .queryItems?.first(where: { $0.name.lowercased() == "p" })?.value
                                .flatMap(Int.init) ?? 1
                            let item = preview.items.first(where: { $0.index == requestedPage }) ?? preview.items[0]
                            displayedPreview = CollectionPreview(
                                sourceURL: preview.sourceURL,
                                title: item.title,
                                items: [item]
                            )
                        } else {
                            displayedPreview = preview
                        }
                        self.collectionTitle = displayedPreview.title
                        self.collectionItems = displayedPreview.items
                        self.collectionSourceURL = displayedPreview.sourceURL.absoluteString
                        self.requiresReanalysisAfterPermanentFailure = false
                        self.state = .idle
                        if !self.applyPendingResumeSnapshotIfNeeded(sourceURL: analysisURL) {
                            self.statusText = preview.items.count == 1
                                ? "解析完成，可以开始下载"
                                : "解析完成，请勾选需要下载的分集"
                        }
                    case .failure(let error):
                        self.state = .failed(error.localizedDescription)
                        self.statusText = "链接解析失败"
                    }
                }
            )
        } catch {
            if activeAnalysisID == analysisID {
                activeAnalysisID = nil
                activeCollectionResolver = nil
                state = .failed("无法启动链接解析：\(error.localizedDescription)")
                statusText = "链接解析失败"
            }
        }
    }

    func setCollectionItemSelected(_ id: String, selected: Bool) {
        guard !isBusy, let index = collectionItems.firstIndex(where: { $0.id == id }) else { return }
        collectionItems[index].isSelected = selected
    }

    func selectAllCollectionItems(_ selected: Bool) {
        guard !isBusy else { return }
        for index in collectionItems.indices {
            collectionItems[index].isSelected = selected
        }
    }

    func start() {
        guard URLClassifier.validatedURL(from: link) != nil else {
            state = .failed("请输入有效的 bilibili.com 或 b23.tv 链接。")
            return
        }
        guard backend.ytDLP != nil else {
            state = .failed("尚未安装 yt-dlp，请先准备下载组件。")
            return
        }
        guard backend.ffmpeg != nil else {
            state = .failed("B站视频与音频通常分开提供，请先补全 FFmpeg 合并组件。")
            return
        }
        guard backend.ffprobe != nil else {
            state = .failed("缺少 FFprobe，无法验证下载文件的音视频轨，请先补全媒体组件。")
            return
        }

        savePreferences()
        wasCancelled = false
        logLines = []
        detailText = ""
        latestFile = nil

        guard hasCurrentCollectionPreview else {
            state = .failed("请先解析链接并确认视频信息。")
            return
        }
        startCollectionQueue()
    }

    func togglePause() {
        guard isDownloading else { return }
        if isPaused {
            pausedForSystemSleep = false
            resumeDownloads(status: "正在继续下载…")
        } else {
            pausedForSystemSleep = false
            pauseDownloads(status: "下载已暂停，临时文件已保留，可随时续传")
        }
    }

    private func pauseDownloads(status: String) {
        guard isDownloading, !isPaused else { return }
        isPaused = true
        statusText = status
        endPowerActivity()
        for index in collectionItems.indices {
            if collectionItems[index].status == .downloading ||
                collectionItems[index].status == .retrying ||
                collectionItems[index].status == .pending {
                collectionItems[index].status = .paused
                collectionItems[index].speedText = ""
            }
        }
        persistResumeSnapshot()
        for (jobID, job) in activeJobs {
            pauseRequestedJobIDs.insert(jobID)
            job.service.cancel()
        }
    }

    private func resumeDownloads(status: String) {
        guard isDownloading, isPaused else { return }
        isPaused = false
        statusText = status
        beginPowerActivity()
        for index in collectionItems.indices where collectionItems[index].status == .paused {
            let id = collectionItems[index].id
            if activeJobs[id] == nil && !pendingItemIDs.contains(id) {
                collectionItems[index].status = .pending
                pendingItemIDs.append(id)
            }
        }
        if let pausedSingleJob {
            self.pausedSingleJob = nil
            launch(request: pausedSingleJob.request, kind: .single, attempt: pausedSingleJob.attempt)
        }
        persistResumeSnapshot()
        pumpQueue()
    }

    private func systemWillSleep() {
        guard isDownloading else { return }
        persistResumeSnapshot()
        guard !isPaused else { return }
        pausedForSystemSleep = true
        pauseDownloads(status: "电脑即将睡眠，任务已安全暂停并保存断点")
    }

    private func systemDidWake() {
        guard pausedForSystemSleep else { return }
        statusText = "电脑已唤醒，正在等待网络恢复…"
        scheduleResumeAfterWake(delayNanoseconds: 5_000_000_000)
    }

    private func scheduleResumeAfterWake(delayNanoseconds: UInt64) {
        guard pausedForSystemSleep else { return }
        wakeResumeTask?.cancel()
        wakeResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard DownloadResumePolicy.shouldAutoResume(
                wasPausedForSystemSleep: self.pausedForSystemSleep,
                isDownloading: self.isDownloading,
                isPaused: self.isPaused
            ) else { return }
            guard self.networkIsAvailable else {
                self.statusText = "网络尚未恢复，任务保持暂停；联网后将自动续传"
                return
            }
            self.pausedForSystemSleep = false
            self.resumeDownloads(status: "电脑已唤醒，正在从断点继续下载…")
        }
    }

    private func installPowerAndNetworkObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }

        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.networkIsAvailable = path.status == .satisfied
                if self.networkIsAvailable, self.pausedForSystemSleep {
                    self.statusText = "网络已恢复，准备自动续传…"
                    self.scheduleResumeAfterWake(delayNanoseconds: 2_000_000_000)
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func beginPowerActivity() {
        guard powerActivity == nil else { return }
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "BiliFetch 正在下载视频"
        )
    }

    private func endPowerActivity() {
        guard let powerActivity else { return }
        ProcessInfo.processInfo.endActivity(powerActivity)
        self.powerActivity = nil
    }

    func cancel() {
        if isAnalyzing {
            pendingResumeSnapshot = nil
            automaticResumeTask?.cancel()
            clearResumeSnapshot()
            statusText = "正在取消链接解析…"
            cancelActiveCollectionAnalysis()
            state = .cancelled
            statusText = "已取消解析"
            return
        }

        guard isDownloading else { return }
        wasCancelled = true
        pausedForSystemSleep = false
        wakeResumeTask?.cancel()
        endPowerActivity()
        clearResumeSnapshot()
        isPaused = false
        pausedSingleJob = nil
        pendingItemIDs.removeAll()
        pauseRequestedJobIDs.removeAll()
        statusText = "正在取消下载…"
        for index in collectionItems.indices where collectionItems[index].status != .completed {
            collectionItems[index].status = .pending
            collectionItems[index].speedText = ""
        }
        for job in activeJobs.values { job.service.cancel() }
        if activeJobs.isEmpty {
            state = .cancelled
            statusText = "已取消"
        }
    }

    func revealDownload() {
        if let latestFile, FileManager.default.fileExists(atPath: latestFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([latestFile])
        } else if collectionItems.count > 1, !collectionTitle.isEmpty {
            NSWorkspace.shared.open(collectionDestination)
        } else {
            NSWorkspace.shared.open(destination)
        }
    }

    private var collectionDestination: URL {
        destination.appendingPathComponent(
            FilenameSanitizer.component(collectionTitle, fallback: "B站合集"),
            isDirectory: true
        )
    }

    private func startCollectionQueue() {
        let selected = collectionItems.filter { $0.isSelected && $0.status != .completed }
        guard !selected.isEmpty else {
            state = .success
            statusText = "选中的视频均已下载完成"
            return
        }

        pendingItemIDs = selected.map(\.id)
        batchItemIDs = Set(pendingItemIDs)
        permanentFailureCount = 0
        completedOutputFiles.removeAll()
        requiresReanalysisAfterPermanentFailure = false
        wasCancelled = false
        isPaused = false
        latestFile = nil
        progress = 0
        for item in selected {
            if let index = collectionItems.firstIndex(where: { $0.id == item.id }) {
                collectionItems[index].status = .pending
                collectionItems[index].progress = 0
                collectionItems[index].speedText = ""
                collectionItems[index].attempt = 0
            }
        }
        state = .downloading
        statusText = "正在启动并行下载…"
        beginPowerActivity()
        persistResumeSnapshot()
        pumpQueue()
    }

    private func pumpQueue() {
        guard state == .downloading, !wasCancelled, !isPaused else { return }

        while activeJobs.count < DownloadConcurrencyPolicy.clamped(downloadConcurrency), !pendingItemIDs.isEmpty {
            let itemID = pendingItemIDs.removeFirst()
            guard let index = collectionItems.firstIndex(where: { $0.id == itemID }),
                  collectionItems[index].isSelected,
                  collectionItems[index].status != .completed else { continue }
            launchCollectionItem(at: index)
        }

        if !activeJobs.isEmpty {
            statusText = "正在同时下载 \(activeJobs.count) 个视频"
        }
        finishBatchIfNeeded()
    }

    private func launchCollectionItem(at index: Int) {
        collectionItems[index].attempt += 1
        collectionItems[index].status = .downloading
        collectionItems[index].speedText = ""
        let item = collectionItems[index]
        let usesCollectionFolder = collectionItems.count > 1
        let request = DownloadRequest(
            url: item.url,
            destination: usesCollectionFolder ? collectionDestination : destination,
            scope: .current,
            quality: quality,
            cookies: cookies,
            includeSubtitles: includeSubtitles,
            engine: engine,
            outputTemplate: usesCollectionFolder
                ? FilenameSanitizer.collectionOutputTemplate(index: item.index, total: item.total, title: item.title)
                : nil,
            cookieFileURL: activeCookieFileURL
        )
        launch(request: request, kind: .collection(itemID: item.id), attempt: item.attempt)
    }

    private func launch(request: DownloadRequest, kind: ActiveDownload, attempt: Int) {
        guard let ytDLP = backend.ytDLP, let ffmpeg = backend.ffmpeg else { return }

        do {
            try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)
        } catch {
            state = .failed("无法创建下载目录：\(error.localizedDescription)")
            statusText = "启动失败"
            return
        }

        let jobID: String
        switch kind {
        case .single: jobID = "single-\(UUID().uuidString)"
        case .collection(let itemID): jobID = itemID
        }
        let service = DownloaderService()
        let delegate = DownloadJobDelegate(
            onLine: { [weak self] line in
                Task { @MainActor in self?.consume(line, jobID: jobID) }
            },
            onFinish: { [weak self] exitCode in
                Task { @MainActor in self?.handleDownloadFinished(jobID: jobID, exitCode: exitCode) }
            }
        )
        service.delegate = delegate
        activeJobs[jobID] = DownloadJob(
            kind: kind,
            request: request,
            startedAt: Date(),
            attempt: attempt,
            service: service,
            delegate: delegate,
            latestFile: nil,
            logLines: []
        )

        let arguments = DownloadArgumentBuilder.arguments(
            for: request,
            ffmpegPath: ffmpeg.path,
            aria2Path: backend.aria2c?.path
        )
        do {
            try service.start(
                executable: ytDLP,
                arguments: arguments,
                toolDirectory: ffmpeg.deletingLastPathComponent()
            )
        } catch {
            if var job = activeJobs[jobID] {
                job.logLines.append(error.localizedDescription)
                activeJobs[jobID] = job
            }
            handleDownloadFinished(jobID: jobID, exitCode: -1)
        }
    }

    private func consume(_ line: String, jobID: String) {
        guard var job = activeJobs[jobID] else { return }
        let cleaned = line
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if job.request.engine == .aria2 {
            let isSummarySeparator = !trimmed.isEmpty && trimmed.allSatisfy { $0 == "=" || $0 == "-" }
            if cleaned.contains("*** Download Progress Summary as of") ||
                trimmed.hasPrefix("FILE:") || isSummarySeparator || trimmed.isEmpty {
                return
            }
        }

        if cleaned.hasPrefix("__PROGRESS__|") {
            let fields = cleaned.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            let numeric = fields.count > 1
                ? fields[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                : ""
            let speed = fields.count > 2 ? normalizedSpeed(fields[2]) : ""
            if let value = Double(numeric) {
                updateProgress(for: job.kind, fraction: value / 100, speed: speed)
            }
            return
        }

        if cleaned.contains("[#"), cleaned.contains("DL:"),
           let percent = firstMatch(in: cleaned, pattern: #"\(([0-9]{1,3})%\)"#),
           let value = Double(percent) {
            var speed = firstMatch(in: cleaned, pattern: #"DL:([^\s\]]+)"#) ?? ""
            if !speed.isEmpty, !speed.hasSuffix("/s") { speed += "/s" }
            updateProgress(for: job.kind, fraction: value / 100, speed: speed)
            return
        }

        if cleaned.hasPrefix("__FILE__|") {
            let path = String(cleaned.dropFirst("__FILE__|".count))
            let file = URL(fileURLWithPath: path)
            job.latestFile = file
            activeJobs[jobID] = job
            latestFile = file
            return
        }

        if cleaned.hasPrefix("__ITEM__|") { return }

        job.logLines.append(cleaned)
        if job.logLines.count > 300 { job.logLines.removeFirst(job.logLines.count - 300) }
        activeJobs[jobID] = job
        logLines.append("[\(jobID)] \(cleaned)")
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
        detailText = logLines.joined(separator: "\n")
    }

    private func normalizedSpeed(_ value: String) -> String {
        let speed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return speed == "NA" ? "" : speed
    }

    private func updateProgress(for kind: ActiveDownload, fraction: Double, speed: String) {
        let value = min(max(fraction, 0), 1)
        switch kind {
        case .single:
            progress = value
        case .collection(let itemID):
            guard let index = collectionItems.firstIndex(where: { $0.id == itemID }) else { return }
            collectionItems[index].progress = value
            collectionItems[index].speedText = speed
            let values = collectionItems.filter { batchItemIDs.contains($0.id) }.map(\.progress)
            progress = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    private func handleDownloadFinished(jobID: String, exitCode: Int32) {
        guard let job = activeJobs.removeValue(forKey: jobID) else { return }
        let completedFile = findCompletedVideo(for: job)
        if let completedFile { latestFile = completedFile }
        let succeeded = DownloadCompletionEvaluator.succeeded(
            exitCode: exitCode,
            hasCompletedVideo: completedFile != nil
        )
        if succeeded, let completedFile {
            completedOutputFiles.insert(completedFile.standardizedFileURL)
        }
        let pauseWasRequested = pauseRequestedJobIDs.remove(jobID) != nil

        if wasCancelled {
            if case .collection(let itemID) = job.kind,
               let index = collectionItems.firstIndex(where: { $0.id == itemID }) {
                collectionItems[index].status = .pending
                collectionItems[index].speedText = ""
            }
            if activeJobs.isEmpty {
                endPowerActivity()
                state = .cancelled
                statusText = "已取消"
            }
            return
        }

        if pauseWasRequested && !succeeded {
            switch job.kind {
            case .single:
                pausedSingleJob = (job.request, job.attempt)
                if !isPaused {
                    let paused = pausedSingleJob
                    pausedSingleJob = nil
                    if let paused { launch(request: paused.request, kind: .single, attempt: paused.attempt) }
                }
            case .collection(let itemID):
                if let index = collectionItems.firstIndex(where: { $0.id == itemID }) {
                    collectionItems[index].status = isPaused ? .paused : .pending
                    collectionItems[index].speedText = ""
                    // Pausing is not a failed attempt. Restore the counter so
                    // relaunching the same partial file keeps its retry budget.
                    collectionItems[index].attempt = max(0, job.attempt - 1)
                }
                if !isPaused && !pendingItemIDs.contains(itemID) { pendingItemIDs.append(itemID) }
            }
            persistResumeSnapshot()
            pumpQueue()
            return
        }

        switch job.kind {
        case .single:
            if succeeded {
                progress = 1
                let cleanedCount = cleanupResidualFilesForCompletedOutputs()
                endPowerActivity()
                clearResumeSnapshot()
                state = .success
                statusText = cleanedCount > 0
                    ? "下载完成，已清理 \(cleanedCount) 个断点文件"
                    : "下载完成"
            } else {
                if DownloadRetryPolicy.shouldRetry(afterAttempt: job.attempt) {
                    statusText = "下载中断，正在从断点自动重试 \(job.attempt)/\(DownloadRetryPolicy.maximumRetries)…"
                    persistResumeSnapshot()
                    launch(request: job.request, kind: .single, attempt: job.attempt + 1)
                } else {
                    removeIncompleteFiles(for: job)
                    endPowerActivity()
                    clearResumeSnapshot()
                    requiresReanalysisAfterPermanentFailure = true
                    state = .failed(friendlyError(from: job.logLines.joined(separator: "\n")))
                    statusText = "重试 3 次后仍失败，请重新解析链接"
                }
            }

        case .collection(let itemID):
            guard let index = collectionItems.firstIndex(where: { $0.id == itemID }) else { return }
            if succeeded {
                collectionItems[index].status = .completed
                collectionItems[index].progress = 1
                collectionItems[index].speedText = ""
            } else {
                collectionItems[index].speedText = ""
                if DownloadRetryPolicy.shouldRetry(afterAttempt: job.attempt) {
                    collectionItems[index].status = .retrying
                    if !pendingItemIDs.contains(itemID) { pendingItemIDs.append(itemID) }
                } else {
                    removeIncompleteFiles(for: job)
                    collectionItems[index].progress = 0
                    collectionItems[index].status = .failed
                    permanentFailureCount += 1
                    clearResumeSnapshot()
                }
            }
            if permanentFailureCount == 0 { persistResumeSnapshot() }
            pumpQueue()
        }
    }

    private func finishBatchIfNeeded() {
        guard !batchItemIDs.isEmpty,
              pendingItemIDs.isEmpty,
              activeJobs.isEmpty,
              !isPaused,
              !wasCancelled else { return }

        isPaused = false
        pausedForSystemSleep = false
        wakeResumeTask?.cancel()
        endPowerActivity()
        clearResumeSnapshot()
        progress = 1
        let cleanedCount = cleanupResidualFilesForCompletedOutputs()
        let completed = collectionItems.filter { batchItemIDs.contains($0.id) && $0.status == .completed }.count
        if permanentFailureCount > 0 {
            requiresReanalysisAfterPermanentFailure = true
            state = .failed("\(permanentFailureCount) 个视频重试 3 次后仍未完成，请重新解析链接后再试。")
            statusText = "完成 \(completed) 个，永久失败 \(permanentFailureCount) 个"
        } else {
            state = .success
            let completionText = batchItemIDs.count == 1 ? "下载完成" : "合集下载完成，共 \(completed) 个视频"
            statusText = cleanedCount > 0
                ? "\(completionText)，已清理 \(cleanedCount) 个断点文件"
                : completionText
        }
    }

    private func requestIdentifiers(_ request: DownloadRequest) -> [String] {
        guard let bvid = URLClassifier.bvid(from: request.url) else { return [] }
        if let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "p" })?.value {
            return collectionItems.count == 1 ? ["\(bvid)_p\(page)", bvid] : ["\(bvid)_p\(page)"]
        }
        return [bvid]
    }

    private func findCompletedVideo(for job: DownloadJob) -> URL? {
        if let file = job.latestFile, isVerifiedCompletedVideo(file) { return file }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: job.request.destination,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let identifiers = requestIdentifiers(job.request)
        let candidates = files.filter(isPlausibleFinalVideo)
        if let matched = candidates.first(where: { file in
            identifiers.contains {
                file.lastPathComponent.range(of: $0, options: .caseInsensitive) != nil
            } && isVerifiedCompletedVideo(file)
        }) { return matched }
        if !identifiers.isEmpty { return nil }

        let threshold = job.startedAt.addingTimeInterval(-3)
        func modificationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return candidates
            .filter { modificationDate($0) >= threshold }
            .sorted { modificationDate($0) > modificationDate($1) }
            .first(where: isVerifiedCompletedVideo)
    }

    private func isPlausibleFinalVideo(_ url: URL) -> Bool {
        guard DownloadOutputValidationPolicy.isPlausibleFinalVideoFileName(url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else { return false }
        return true
    }

    private func isVerifiedCompletedVideo(_ url: URL) -> Bool {
        guard isPlausibleFinalVideo(url), let ffprobe = backend.ffprobe else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            "--", url.path
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let streamTypes = Set(
            text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map { $0.lowercased() }
        )
        return streamTypes.contains("video") && streamTypes.contains("audio")
    }

    private func cleanupResidualFilesForCompletedOutputs() -> Int {
        var cleanedFiles: Set<URL> = []
        for completedFile in completedOutputFiles where isVerifiedCompletedVideo(completedFile) {
            let directory = completedFile.deletingLastPathComponent()
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                guard DownloadResidualFilePolicy.belongsToCompletedFile(
                    residualFileName: file.lastPathComponent,
                    completedFileName: completedFile.lastPathComponent
                ) else { continue }
                let standardizedFile = file.standardizedFileURL
                guard !cleanedFiles.contains(standardizedFile) else { continue }
                do {
                    try FileManager.default.removeItem(at: standardizedFile)
                    cleanedFiles.insert(standardizedFile)
                } catch {
                    logLines.append("无法清理断点文件 \(file.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
        if !cleanedFiles.isEmpty {
            logLines.append("下载完成后已清理 \(cleanedFiles.count) 个 .part/.aria2 断点文件")
            detailText = logLines.joined(separator: "\n")
        }
        return cleanedFiles.count
    }

    private func removeIncompleteFiles(for job: DownloadJob) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: job.request.destination,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let identifiers = requestIdentifiers(job.request)
        let intermediatePattern = #"\.f[0-9]+\.(mp4|m4a|webm|flv)$"#
        let threshold = job.startedAt.addingTimeInterval(-3)
        for file in files {
            let name = file.lastPathComponent
            let lower = name.lowercased()
            let isTemporary = lower.contains(".part") || lower.hasSuffix(".ytdl") ||
                lower.hasSuffix(".aria2") || lower.hasSuffix(".tmp") || lower.hasSuffix(".temp") ||
                lower.range(of: intermediatePattern, options: .regularExpression) != nil
            guard isTemporary else { continue }

            let belongsToRequest: Bool
            if identifiers.isEmpty {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                belongsToRequest = modified >= threshold
            } else {
                belongsToRequest = identifiers.contains {
                    name.range(of: $0, options: .caseInsensitive) != nil
                }
            }
            guard belongsToRequest else { continue }
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logLines.append("无法清理临时文件 \(name)：\(error.localizedDescription)")
            }
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func friendlyError(from log: String) -> String {
        let lower = log.lowercased()
        if lower.contains("aria2c") && (lower.contains("exited with code") || lower.contains("error")) {
            return "可切换到“标准（yt-dlp）”后继续；已完成的项目不会重复下载。"
        }
        if lower.contains("login required") || lower.contains("sign in") || lower.contains("登录") {
            return "该内容需要登录，请在高级选项中扫码登录 B 站，或选择已登录的浏览器。"
        }
        if lower.contains("412") || lower.contains("-352") || lower.contains("request is blocked") {
            return "B站暂时拒绝了请求，请稍后重试，或在高级选项中扫码登录。"
        }
        if lower.contains("unsupported url") {
            return "无法识别这个链接，请使用完整的视频或合集链接。"
        }
        if lower.contains("ffmpeg") && lower.contains("not found") {
            return "缺少 FFmpeg，无法合并高画质音视频。"
        }
        if lower.contains("http error 403") {
            return "访问被拒绝（403），可尝试登录或稍后重试。"
        }
        return "下载未完成，请重新解析链接后再试。"
    }

    private func clearCollectionPreview() {
        collectionSourceURL = nil
        collectionTitle = ""
        collectionItems = []
        pendingItemIDs = []
        batchItemIDs = []
        completedOutputFiles.removeAll()
        permanentFailureCount = 0
        requiresReanalysisAfterPermanentFailure = false
    }

    private func cancelActiveCollectionAnalysis() {
        activeAnalysisID = nil
        activeCollectionResolver?.cancel()
        activeCollectionResolver = nil
    }

    private func scheduleAutomaticCollectionAnalysis() {
        guard !hasCurrentCollectionPreview,
              URLClassifier.validatedURL(from: link) != nil,
              backend.ytDLP != nil else { return }

        statusText = needsAutomaticScopeDetection
            ? "正在解析链接并识别分集…"
            : "正在准备分集列表…"
        automaticAnalysisTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.canAnalyzeCollection,
                  !self.hasCurrentCollectionPreview else { return }
            self.resolveCollection(isAutomaticProbe: self.scope == .automatic)
        }
    }

    private func restoreUnfinishedDownloadIfNeeded() {
        guard let snapshot = savedResumeSnapshot() else { return }
        guard URLClassifier.validatedURL(from: snapshot.sourceURL) != nil,
              !snapshot.destinationPath.isEmpty,
              !snapshot.remainingIndexes.isEmpty else {
            clearResumeSnapshot()
            return
        }

        pendingResumeSnapshot = snapshot
        link = snapshot.sourceURL
        destination = URL(fileURLWithPath: snapshot.destinationPath, isDirectory: true)
        scope = DownloadScope(rawValue: snapshot.scope) ?? .automatic
        quality = VideoQuality(rawValue: snapshot.quality) ?? .best
        cookies = BrowserCookies(rawValue: snapshot.cookies) ?? .none
        includeSubtitles = snapshot.includeSubtitles
        engine = DownloadEngine(rawValue: snapshot.engine) ?? .aria2
        downloadConcurrency = DownloadConcurrencyPolicy.clamped(snapshot.concurrency)
        statusText = "检测到未完成任务，正在自动解析并准备续传…"
        linkDidChange()
    }

    @discardableResult
    private func applyPendingResumeSnapshotIfNeeded(sourceURL: String) -> Bool {
        guard let snapshot = pendingResumeSnapshot,
              snapshot.sourceURL == sourceURL else { return false }

        let availableIndexes = Set(collectionItems.map(\.index))
        let remainingIndexes = Set(snapshot.remainingIndexes).intersection(availableIndexes)
        let selectedIndexes = Set(snapshot.selectedIndexes)
            .union(remainingIndexes)
            .intersection(availableIndexes)
        guard !remainingIndexes.isEmpty else {
            clearResumeSnapshot()
            return false
        }

        for index in collectionItems.indices {
            let itemIndex = collectionItems[index].index
            collectionItems[index].isSelected = selectedIndexes.contains(itemIndex)
            if selectedIndexes.contains(itemIndex), !remainingIndexes.contains(itemIndex) {
                collectionItems[index].status = .completed
                collectionItems[index].progress = 1
            } else {
                collectionItems[index].status = .pending
                collectionItems[index].progress = 0
            }
            collectionItems[index].speedText = ""
            collectionItems[index].attempt = 0
        }

        pendingResumeSnapshot = nil
        statusText = "已恢复未完成任务，将从断点自动续传…"
        automaticResumeTask?.cancel()
        automaticResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  let self,
                  URLClassifier.validatedURL(from: self.link)?.absoluteString == sourceURL,
                  self.canStart else { return }
            self.start()
        }
        return true
    }

    private func persistResumeSnapshot() {
        guard isDownloading,
              !batchItemIDs.isEmpty,
              let sourceURL = URLClassifier.validatedURL(from: link)?.absoluteString else { return }

        let selected = collectionItems.filter(\.isSelected)
        let remaining = selected.filter { item in
            item.status != .completed && item.status != .failed
        }
        guard !remaining.isEmpty else {
            clearResumeSnapshot()
            return
        }

        let snapshot = ResumeSnapshot(
            sourceURL: sourceURL,
            destinationPath: destination.path,
            scope: scope.rawValue,
            quality: quality.rawValue,
            cookies: cookies.rawValue,
            includeSubtitles: includeSubtitles,
            engine: engine.rawValue,
            concurrency: DownloadConcurrencyPolicy.clamped(downloadConcurrency),
            selectedIndexes: selected.map(\.index).sorted(),
            remainingIndexes: remaining.map(\.index).sorted()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: resumeSnapshotKey)
        defaults.synchronize()
    }

    private func savedResumeSnapshot() -> ResumeSnapshot? {
        guard let data = defaults.data(forKey: resumeSnapshotKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ResumeSnapshot.self, from: data) else {
            defaults.removeObject(forKey: resumeSnapshotKey)
            return nil
        }
        return snapshot
    }

    private func clearResumeSnapshot() {
        automaticResumeTask?.cancel()
        automaticResumeTask = nil
        pendingResumeSnapshot = nil
        defaults.removeObject(forKey: resumeSnapshotKey)
        defaults.synchronize()
    }

    private func savePreferences() {
        defaults.set(scope.rawValue, forKey: "downloadScope")
        defaults.set(quality.rawValue, forKey: "videoQuality")
        defaults.set(cookies.rawValue, forKey: "browserCookies")
        defaults.set(includeSubtitles, forKey: "includeSubtitles")
        defaults.set(engine.rawValue, forKey: "downloadEngine")
        defaults.set(DownloadConcurrencyPolicy.clamped(downloadConcurrency), forKey: "downloadConcurrency")
    }

    private var activeCookieFileURL: URL? {
        guard isBilibiliLoggedIn,
              FileManager.default.fileExists(atPath: BilibiliAuthService.cookieFileURL.path) else {
            return nil
        }
        return BilibiliAuthService.cookieFileURL
    }
}
