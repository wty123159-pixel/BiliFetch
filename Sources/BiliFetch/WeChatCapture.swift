import AppKit
import Foundation
import SwiftUI

struct WeChatCapturedVideo: Codable, Identifiable {
    let id: String
    let title: String
    let author: String
    let thumbnail: String
    let duration: Double
    let sourceURL: String
    let capturedAt: Int64
    let formatCount: Int
}

private struct CaptureState: Decodable {
    let active: Bool
    let message: String
    let pages: Int
    let scripts: Int
    let captures: [WeChatCapturedVideo]
}

enum WeChatCaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class WeChatCaptureController: ObservableObject {
    @Published var active = false
    @Published var busy = false
    @Published var message = "开启后，在电脑微信中重新打开并播放目标视频。"
    @Published var videos: [WeChatCapturedVideo] = []
    @Published var error: String?
    private var process: Process?
    private var input: Pipe?
    private var baseURL: URL?
    private var token = ""
    private var startup: Task<Void, Error>?
    private var timer: Timer?
    private var polling = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 50
        return URLSession(configuration: configuration)
    }()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BiliFetch/WeChatCapture", isDirectory: true)
    }
    var isRunning: Bool { process?.isRunning == true }

    func recoverIfNeeded() {
        if FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("proxy-restore.json").path) {
            Task { await refresh() }
        }
    }

    func ensureReady() async throws {
        if isRunning, baseURL != nil { return }
        if let startup { return try await startup.value }
        let task = Task { @MainActor in try await self.launch() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/wechat-capture/bilifetch-capture-macos")
        guard let executable = BackendLocator.locateExecutable(named: "bilifetch-capture")
            ?? (FileManager.default.isExecutableFile(atPath: source.path) ? source : nil) else {
            throw WeChatCaptureError.message("视频号捕获组件缺失，请重新安装完整版本。")
        }
        let task = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = executable
        task.arguments = ["--data-dir", Self.directory.path]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        try task.run()
        let startupDeadline = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: startupDeadline)
        defer { startupDeadline.cancel() }
        process = task; input = stdin
        task.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.baseURL = nil; self.token = ""; self.active = false; self.process = nil
            }
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = Data()
                while bytes.count < 16384 {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                    if bytes.contains(10) { break }
                }
                if !bytes.isEmpty { continuation.resume(returning: bytes) }
                else {
                    let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
                    let object = (try? JSONSerialization.jsonObject(with: diagnostic)) as? [String: Any]
                    continuation.resume(throwing: WeChatCaptureError.message(object?["error"] as? String ?? "视频号捕获组件未能启动。"))
                }
            }
        }
        guard let ready = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              ready["event"] == "ready", let address = ready["baseURL"], let url = URL(string: address),
              url.scheme == "http", url.host == "127.0.0.1", let secret = ready["token"], secret.count == 64 else {
            try? stdin.fileHandleForWriting.close()
            throw WeChatCaptureError.message("视频号捕获组件返回了无效的启动信息。")
        }
        baseURL = url; token = secret
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        try await ensureReady()
        guard let baseURL else { throw WeChatCaptureError.message("本机捕获连接尚未准备好。") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw WeChatCaptureError.message(object?["error"] as? String ?? "本机捕获请求失败，请导出诊断报告。")
        }
        return data
    }
    private func apply(_ data: Data) throws {
        let state = try JSONDecoder().decode(CaptureState.self, from: data)
        active = state.active; message = state.message; videos = state.captures
    }
    func refresh() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        do { try apply(await request("api/state")); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func openPanel() {
        Task { await refresh() }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }
    func closePanel() { timer?.invalidate(); timer = nil }
    func start() async {
        busy = true; error = nil
        defer { busy = false }
        do { try apply(await request("api/start", method: "POST", body: ["consent": true])) }
        catch { self.error = error.localizedDescription }
    }
    func stop() async throws {
        guard isRunning else { return }
        try apply(await request("api/stop", method: "POST"))
    }
    func stopFromUI() async {
        busy = true
        defer { busy = false }
        do { try await stop(); error = nil } catch { self.error = error.localizedDescription }
    }
    func clear() async {
        do { try apply(await request("api/clear", method: "POST")); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func manifest(id: String) async throws -> URL {
        guard id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw WeChatCaptureError.message("捕获作品标识无效。")
        }
        let data = try await request("api/manifest/\(id)")
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let path = object["path"] else { throw WeChatCaptureError.message("未取得捕获作品的下载信息。") }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let expected = Self.directory.appendingPathComponent("Captures/\(id).info.json").standardizedFileURL
        guard file == expected else { throw WeChatCaptureError.message("捕获下载信息的路径无效。") }
        return file
    }
    func capturedVideos(ids: [String]) async throws -> [WeChatCapturedVideo] {
        try apply(await request("api/state"))
        return try ids.map { id in
            guard let video = videos.first(where: { $0.id == id }) else {
                throw WeChatCaptureError.message("部分捕获记录已不存在，请在微信重新播放。")
            }
            return video
        }
    }
    func exportDiagnostics() async {
        do {
            let data = try await request("api/diagnostics")
            var report = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            report["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            report["system"] = ProcessInfo.processInfo.operatingSystemVersionString
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.xinWeChat"),
               let bundle = Bundle(url: app) { report["wechatVersion"] = bundle.infoDictionary?["CFBundleShortVersionString"] }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "记住你宇哥-视频号诊断.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { self.error = error.localizedDescription }
    }
    func shutdown() async throws {
        timer?.invalidate(); timer = nil
        if isRunning { try await stop(); try input?.fileHandleForWriting.close() }
    }
}

struct WeChatCaptureSheet: View {
    @ObservedObject var model: DownloadViewModel
    @ObservedObject var capture: WeChatCaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var showConsent = false
    @State private var selected = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("视频号播放捕获").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("开启捕获后，在电脑微信中重新打开并播放目标视频。只收录当前实际播放的作品，预加载视频不会进入列表。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(capture.active ? "关闭捕获" : "开启捕获") {
                    if capture.active { Task { await capture.stopFromUI() } } else { showConsent = true }
                }.buttonStyle(.borderedProminent).disabled(capture.busy)
                Button("打开微信") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.xinWeChat") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                Button("导出诊断") { Task { await capture.exportDiagnostics() } }
                Spacer()
                Button("清空记录") { Task { await capture.clear(); selected.removeAll() } }.disabled(model.isBusy)
            }
            Text(capture.message).font(.callout)
            if let error = capture.error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            List(capture.videos) { video in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: {selected.contains(video.id)}, set: {if $0 {selected.insert(video.id)} else {selected.remove(video.id)}})).labelsHidden()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).lineLimit(2)
                        Text("\(video.author) · \(video.formatCount) 个可用画质").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }.overlay { if capture.videos.isEmpty { Text("等待你在微信中播放视频…").foregroundStyle(.secondary) } }
            HStack {
                Text("关闭捕获会恢复网络设置，列表中的作品仍可下载。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("加入下载列表") {
                    model.useWeChatCaptures(capture.videos.filter { selected.contains($0.id) })
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || model.isBusy)
            }
        }
        .padding(22).frame(width: 700, height: 490)
        .onAppear { capture.openPanel() }
        .onDisappear { capture.closePanel() }
        .alert("开启本机视频号捕获？", isPresented: $showConsent) {
            Button("取消", role: .cancel) {}
            Button("开启捕获") { Task { await capture.start() } }
        } message: {
            Text("需要信任本机独立生成的捕获证书，并临时设置网络代理。只处理视频号页面，关闭捕获或正常退出时恢复原设置。证书和私钥不随软件分发；停止捕获后保留本机证书，方便下次使用。首次启用可能出现系统授权提示。")
        }
    }
}
