import Foundation

struct AppUpdateRelease: Equatable {
    let version: String
    let notes: String
    let url: URL
    let sha256: String
    let size: Int64
}

struct AppUpdateManifest: Decodable {
    struct Artifact: Decodable {
        let version: String?
        let notes: String?
        let url: String
        let sha256: String
        let size: Int64?
    }

    let version: String?
    let notes: String?
    let macos: Artifact?

    func macOSRelease() throws -> AppUpdateRelease {
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
        return AppUpdateRelease(
            version: releaseVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            notes: macos.notes ?? notes ?? "本次更新暂无说明。",
            url: url,
            sha256: digest,
            size: macos.size ?? 0
        )
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
    case appLocationNotWritable
    case developmentBuild

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return message
        case .notConfigured: return "尚未配置固定的更新清单地址。"
        case .downloadFailed(let message): return "更新下载失败：\(message)"
        case .checksumMismatch: return "更新包 SHA-256 校验失败，已删除可疑文件。"
        case .archiveInvalid: return "更新包中没有找到 BiliFetch.app。"
        case .appLocationNotWritable: return "当前应用所在目录不可写，请把 BiliFetch 放到个人“应用程序”或其他可写目录后再升级。"
        case .developmentBuild: return "开发运行模式不能执行原地升级。"
        }
    }
}
