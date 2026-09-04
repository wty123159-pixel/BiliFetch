import Foundation

struct AppUpdateRelease: Equatable {
    let version: String
    let notes: String
    let url: URL
    let sha256: String
    let size: Int64
    let delta: AppUpdateDelta?

    var fullAsset: AppUpdateAsset {
        AppUpdateAsset(kind: .full, url: url, sha256: sha256, size: size)
    }

    var preferredAsset: AppUpdateAsset {
        guard let delta else { return fullAsset }
        return AppUpdateAsset(kind: .delta, url: delta.url, sha256: delta.sha256, size: delta.size)
    }
}

struct AppUpdateDelta: Equatable {
    let fromVersion: String
    let url: URL
    let sha256: String
    let size: Int64
}

struct AppUpdateAsset: Equatable {
    enum Kind: Equatable {
        case full
        case delta
    }

    let kind: Kind
    let url: URL
    let sha256: String
    let size: Int64
}

struct UpdateTransferProgress: Equatable {
    let fraction: Double
    let speed: String
}

enum UpdateProgressParser {
    static func aria2(_ line: String) -> UpdateTransferProgress? {
        let pattern = #"\(([0-9]{1,3})%\).*?DL:([^\s\]]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.matches(in: line, range: range).last,
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else { return nil }
        let speed = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
        return UpdateTransferProgress(
            fraction: min(max(percent / 100, 0), 1),
            speed: speed.isEmpty || speed.hasSuffix("/s") ? speed : "\(speed)/s"
        )
    }
}

struct AppUpdateManifest: Decodable {
    struct Delta: Decodable {
        let fromVersion: String
        let url: String
        let sha256: String
        let size: Int64?
    }

    struct Artifact: Decodable {
        let version: String?
        let notes: String?
        let url: String
        let sha256: String
        let size: Int64?
        let deltas: [Delta]?
    }

    let version: String?
    let notes: String?
    let macos: Artifact?

    func macOSRelease(currentVersion: String? = nil) throws -> AppUpdateRelease {
        guard let macos else { throw AppUpdateError.invalidManifest("更新清单缺少 macOS 下载信息。") }
        let releaseVersion = macos.version ?? version ?? ""
        guard AppVersion.components(releaseVersion) != nil else {
            throw AppUpdateError.invalidManifest("macOS 版本号格式无效。")
        }
        guard let url = URL(string: macos.url), url.scheme?.lowercased() == "https" else {
            throw AppUpdateError.invalidManifest("macOS 更新包必须使用 HTTPS。")
        }
        let digest = macos.sha256.lowercased()
        guard digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw AppUpdateError.invalidManifest("macOS 更新包缺少有效的 SHA-256。")
        }
        let matchingDeltaSource = macos.deltas?.first { delta in
            guard let currentVersion else { return false }
            return (try? AppVersion.compare(delta.fromVersion, currentVersion)) == .orderedSame
        }
        let matchingDelta = try matchingDeltaSource.map { delta -> AppUpdateDelta in
            guard let deltaURL = URL(string: delta.url), deltaURL.scheme?.lowercased() == "https" else {
                throw AppUpdateError.invalidManifest("macOS 增量更新包必须使用 HTTPS。")
            }
            let deltaDigest = delta.sha256.lowercased()
            guard deltaDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw AppUpdateError.invalidManifest("macOS 增量更新包缺少有效的 SHA-256。")
            }
            return AppUpdateDelta(
                fromVersion: delta.fromVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                url: deltaURL,
                sha256: deltaDigest,
                size: delta.size ?? 0
            )
        }
        return AppUpdateRelease(
            version: releaseVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            notes: macos.notes ?? notes ?? "本次更新暂无说明。",
            url: url,
            sha256: digest,
            size: macos.size ?? 0,
            delta: matchingDelta
        )
    }
}

struct AppDeltaPlan: Decodable {
    struct FileEntry: Decodable {
        struct BinaryPatch: Decodable {
            struct Operation: Decodable {
                let type: String
                let offset: Int64
                let length: Int64
            }

            let source: String
            let baseSha256: String
            let baseSize: Int64
            let dataSha256: String
            let dataSize: Int64
            let operations: [Operation]
        }

        let path: String
        let sha256: String
        let size: Int64
        let mode: Int?
        let patch: BinaryPatch?
    }

    let formatVersion: Int
    let platform: String
    let fromVersion: String
    let toVersion: String
    let files: [FileEntry]
    let deletePaths: [String]

    func validate(currentVersion: String, targetVersion: String) throws {
        guard formatVersion == 1, platform == "macos",
              try AppVersion.compare(fromVersion, currentVersion) == .orderedSame,
              try AppVersion.compare(toVersion, targetVersion) == .orderedSame else {
            throw AppUpdateError.invalidDelta("增量包版本与当前应用不匹配。")
        }
        var paths = Set<String>()
        for file in files {
            guard Self.isSafeRelativePath(file.path), paths.insert(file.path).inserted,
                  file.size >= 0,
                  file.mode.map({ (0...0o7777).contains($0) }) ?? true,
                  file.sha256.lowercased().range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw AppUpdateError.invalidDelta("增量包包含无效文件记录。")
            }
            if let patch = file.patch {
                guard Self.isSafeRelativePath(patch.source), patch.baseSize >= 0, patch.dataSize >= 0,
                      patch.baseSha256.lowercased().range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      patch.dataSha256.lowercased().range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw AppUpdateError.invalidDelta("增量包包含无效的二进制补丁。")
                }
                var outputSize: Int64 = 0
                var nextDataOffset: Int64 = 0
                for operation in patch.operations {
                    guard operation.offset >= 0, operation.length > 0,
                          outputSize <= Int64.max - operation.length else {
                        throw AppUpdateError.invalidDelta("二进制补丁范围无效。")
                    }
                    if operation.type == "copy" {
                        guard operation.offset <= patch.baseSize,
                              operation.length <= patch.baseSize - operation.offset else {
                            throw AppUpdateError.invalidDelta("二进制补丁读取范围无效。")
                        }
                    } else if operation.type == "data" {
                        guard operation.offset == nextDataOffset,
                              operation.offset <= patch.dataSize,
                              operation.length <= patch.dataSize - operation.offset else {
                            throw AppUpdateError.invalidDelta("二进制补丁数据范围无效。")
                        }
                        nextDataOffset += operation.length
                    } else {
                        throw AppUpdateError.invalidDelta("二进制补丁操作无效。")
                    }
                    outputSize += operation.length
                }
                guard outputSize == file.size, nextDataOffset == patch.dataSize else {
                    throw AppUpdateError.invalidDelta("二进制补丁大小不一致。")
                }
            }
        }
        for path in deletePaths {
            guard Self.isSafeRelativePath(path), paths.insert(path).inserted else {
                throw AppUpdateError.invalidDelta("增量包包含不安全的删除路径。")
            }
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum AppVersion {
    static func components(_ value: String) -> [Int]? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let base = clean.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let parts = base.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    static func compare(_ left: String, _ right: String) throws -> ComparisonResult {
        guard let lhs = components(left), let rhs = components(right) else {
            throw AppUpdateError.invalidManifest("更新版本号格式无效。")
        }
        for index in 0..<3 where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

enum AppUpdateError: LocalizedError {
    case invalidManifest(String)
    case notConfigured
    case downloadFailed(String)
    case checksumMismatch
    case archiveInvalid
    case invalidDelta(String)
    case appLocationNotWritable
    case developmentBuild

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return message
        case .notConfigured: return "尚未配置固定的更新清单地址。"
        case .downloadFailed(let message): return "更新下载失败：\(message)"
        case .checksumMismatch: return "更新包 SHA-256 校验失败，已删除可疑文件。"
        case .archiveInvalid: return "更新包中没有找到 BiliFetch.app。"
        case .invalidDelta(let message): return message
        case .appLocationNotWritable: return "当前应用所在目录不可写，请把 BiliFetch 放到个人“应用程序”或其他可写目录后再升级。"
        case .developmentBuild: return "开发运行模式不能执行原地升级。"
        }
    }
}
