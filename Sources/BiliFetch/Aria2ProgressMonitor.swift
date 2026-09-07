import Foundation

struct Aria2RPCConfiguration: Equatable {
    let port: Int
    let secret: String

    static func make(avoiding reservedPorts: Set<Int>) -> Aria2RPCConfiguration {
        let range = 49_152...65_000
        var port = Int.random(in: range)
        for _ in 0..<128 {
            if !reservedPorts.contains(port) { break }
            port = Int.random(in: range)
        }
        return Aria2RPCConfiguration(
            port: port,
            secret: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        )
    }
}

struct Aria2LiveProgress: Equatable {
    let fraction: Double
    let speedText: String
}

/// Reads aria2 directly over its loopback-only JSON-RPC endpoint. yt-dlp only
/// emits its own progress hook after an external downloader finishes, so its
/// progress template cannot provide a continuous UI by itself.
final class Aria2ProgressMonitor: @unchecked Sendable {
    private struct Transfer {
        let gid: String
        let status: String
        let totalLength: Int64
        let completedLength: Int64
        let downloadSpeed: Int64
    }

    private let configuration: Aria2RPCConfiguration
    private var pollingTask: Task<Void, Never>?
    private var seenSessionIDs: [String] = []
    private var shutdownSessionIDs: Set<String> = []

    init(configuration: Aria2RPCConfiguration) {
        self.configuration = configuration
    }

    func start(onProgress: @escaping @Sendable (Aria2LiveProgress) -> Void) {
        pollingTask?.cancel()
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            await self?.poll(onProgress: onProgress)
        }
    }

    func stop(forceShutdown: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        guard forceShutdown else { return }
        let configuration = configuration
        Task.detached(priority: .utility) {
            _ = try? await Self.call(
                configuration: configuration,
                method: "aria2.forceShutdown",
                parameters: []
            )
        }
    }

    private func poll(onProgress: @escaping @Sendable (Aria2LiveProgress) -> Void) async {
        while !Task.isCancelled {
            do {
                let sessionID = try await sessionIdentifier()
                let stage = register(sessionID: sessionID)
                async let activeRequest = transfers(method: "aria2.tellActive", parameters: [])
                async let waitingRequest = transfers(method: "aria2.tellWaiting", parameters: [0, 1_000])
                async let stoppedRequest = transfers(method: "aria2.tellStopped", parameters: [0, 1_000])
                let (active, waiting, stopped) = try await (activeRequest, waitingRequest, stoppedRequest)

                if !active.isEmpty || !waiting.isEmpty {
                    let rawFraction = Self.aggregateFraction(active: active, waiting: waiting, stopped: stopped)
                    let overall = Self.overallFraction(rawFraction: rawFraction, stage: stage)
                    let speed = Self.speedText(
                        bytesPerSecond: active.reduce(0) { $0 + $1.downloadSpeed },
                        stage: stage
                    )
                    onProgress(Aria2LiveProgress(fraction: overall, speedText: speed))
                } else if !stopped.isEmpty, !shutdownSessionIDs.contains(sessionID) {
                    let completed = stopped.allSatisfy { $0.status == "complete" }
                    onProgress(Aria2LiveProgress(
                        fraction: Self.overallFraction(
                            rawFraction: Self.aggregateFraction(active: [], waiting: [], stopped: stopped),
                            stage: stage
                        ),
                        speedText: completed ? Self.waitingText(after: stage) : "下载阶段结束，正在检查…"
                    ))
                    // RPC mode intentionally keeps aria2 alive. Shut down this
                    // completed media-stream process so yt-dlp can start the
                    // next stream or merge the final file.
                    _ = try await rpc(method: "aria2.shutdown", parameters: [])
                    shutdownSessionIDs.insert(sessionID)
                }
            } catch {
                // The endpoint normally does not exist while yt-dlp resolves
                // metadata, between video/audio streams, or after completion.
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private func register(sessionID: String) -> Int {
        if !seenSessionIDs.contains(sessionID) { seenSessionIDs.append(sessionID) }
        return max(1, seenSessionIDs.firstIndex(of: sessionID).map { $0 + 1 } ?? seenSessionIDs.count)
    }

    private func sessionIdentifier() async throws -> String {
        let result = try await rpc(method: "aria2.getSessionInfo", parameters: [])
        guard let value = result as? [String: Any], let sessionID = value["sessionId"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return sessionID
    }

    private func transfers(method: String, parameters: [Any]) async throws -> [Transfer] {
        let result = try await rpc(
            method: method,
            parameters: parameters + [["gid", "status", "totalLength", "completedLength", "downloadSpeed"]]
        )
        guard let values = result as? [[String: Any]] else { return [] }
        return values.compactMap(Self.transfer(from:))
    }

    private func rpc(method: String, parameters: [Any]) async throws -> Any {
        try await Self.call(configuration: configuration, method: method, parameters: parameters)
    }

    private static func call(
        configuration: Aria2RPCConfiguration,
        method: String,
        parameters: [Any]
    ) async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(configuration.port)/jsonrpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 0.8
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "bilifetch",
            "method": method,
            "params": ["token:\(configuration.secret)"] + parameters
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let result = object["result"] else {
            throw URLError(.badServerResponse)
        }
        return result
    }

    private static func transfer(from value: Any) -> Transfer? {
        guard let value = value as? [String: Any],
              let gid = value["gid"] as? String else { return nil }
        return Transfer(
            gid: gid,
            status: value["status"] as? String ?? "",
            totalLength: Int64(value["totalLength"] as? String ?? "") ?? 0,
            completedLength: Int64(value["completedLength"] as? String ?? "") ?? 0,
            downloadSpeed: Int64(value["downloadSpeed"] as? String ?? "") ?? 0
        )
    }

    private static func aggregateFraction(
        active: [Transfer],
        waiting: [Transfer],
        stopped: [Transfer]
    ) -> Double {
        let transfers = active + waiting + stopped
        guard !transfers.isEmpty else { return 0 }
        let fractions = transfers.map { transfer -> Double in
            if transfer.status == "complete" { return 1 }
            guard transfer.totalLength > 0 else { return 0 }
            return min(max(Double(transfer.completedLength) / Double(transfer.totalLength), 0), 1)
        }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    static func overallFraction(rawFraction: Double, stage: Int) -> Double {
        let raw = min(max(rawFraction, 0), 1)
        switch stage {
        case 1: return raw * 0.90
        case 2: return 0.90 + raw * 0.08
        default: return min(0.995, 0.98 + raw * 0.015)
        }
    }

    private static func speedText(bytesPerSecond: Int64, stage: Int) -> String {
        let phase = stage == 1 ? "视频流" : (stage == 2 ? "音频流" : "媒体流")
        guard bytesPerSecond > 0 else { return "正在连接\(phase)…" }
        return "\(ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary))/s · \(phase)"
    }

    private static func waitingText(after stage: Int) -> String {
        stage == 1 ? "视频流完成，正在准备音频…" : "媒体下载完成，正在合并…"
    }
}
