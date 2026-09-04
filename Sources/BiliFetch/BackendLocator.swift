import Foundation

struct BackendStatus: Equatable {
    let ytDLP: URL?
    let ffmpeg: URL?
    let ffprobe: URL?
    let aria2c: URL?

    var canDownload: Bool { ytDLP != nil }
    var hasFullQualitySupport: Bool { ytDLP != nil && ffmpeg != nil && ffprobe != nil }
    var hasAccelerationSupport: Bool { aria2c != nil }
}

enum BackendLocator {
    static var applicationSupportToolsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BiliFetch/Tools", isDirectory: true)
    }

    static func locate() -> BackendStatus {
        BackendStatus(
            ytDLP: locateExecutable(named: "yt-dlp"),
            ffmpeg: locateExecutable(named: "ffmpeg"),
            ffprobe: locateExecutable(named: "ffprobe"),
            aria2c: locateExecutable(named: "aria2c")
        )
    }

    static func locateExecutable(named name: String) -> URL? {
        var candidates: [URL] = []

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Tools/\(name)"))
        }

        candidates.append(applicationSupportToolsDirectory.appendingPathComponent(name))

        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)"
        ].forEach { candidates.append(URL(fileURLWithPath: $0)) }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var bundledSetupScript: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("prepare-tools.command")
            .existingFile
    }
}

private extension URL {
    var existingFile: URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
