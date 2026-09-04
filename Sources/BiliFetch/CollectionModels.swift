import Foundation

enum CollectionItemStatus: String, Equatable {
    case pending
    case downloading
    case paused
    case retrying
    case completed
    case failed
}

struct CollectionItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let total: Int
    let title: String
    let url: URL
    let thumbnailURL: URL?
    let duration: TimeInterval?
    var isSelected: Bool
    var status: CollectionItemStatus
    var progress: Double = 0
    var speedText: String = ""
    var attempt: Int = 0

    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let seconds = Int(duration.rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

struct CollectionPreview: Equatable {
    let sourceURL: URL
    let title: String
    var items: [CollectionItem]
}

enum CollectionMetadataError: LocalizedError {
    case noItems
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .noItems: return "没有从该链接中找到可下载的视频。"
        case .malformedOutput: return "合集列表格式无法识别，请更新 yt-dlp 后重试。"
        }
    }
}

enum CollectionMetadataParser {
    static func parse(lines: [String], sourceURL: URL) throws -> CollectionPreview {
        var records: [[String: Any]] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any] else {
                continue
            }
            records.append(record)
        }

        guard !records.isEmpty else { throw CollectionMetadataError.noItems }

        let rawCollectionTitle = string(in: records[0], keys: ["playlist_title", "playlist"])
            ?? string(in: records[0], keys: ["title"])
            ?? "B站合集"
        let collectionTitle = FilenameSanitizer.component(rawCollectionTitle, fallback: "B站合集")
        let reportedTotal = integer(in: records[0], keys: ["playlist_count"]) ?? records.count

        var items: [CollectionItem] = []
        for (offset, record) in records.enumerated() {
            let index = integer(in: record, keys: ["playlist_index"]) ?? offset + 1
            guard let urlText = string(in: record, keys: ["webpage_url", "original_url", "url"]),
                  let url = URLClassifier.validatedURL(from: urlText) else {
                continue
            }

            let rawTitle = string(in: record, keys: ["title"]) ?? "第 \(index) 集"
            let title = conciseTitle(rawTitle, collectionTitle: rawCollectionTitle, index: index)
            let rawID = string(in: record, keys: ["id"]) ?? url.absoluteString
            let thumbnailURL = secureURL(from: string(in: record, keys: ["thumbnail"]))
            let duration = number(in: record, keys: ["duration"])

            items.append(CollectionItem(
                id: "\(rawID)#\(index)",
                index: index,
                total: max(reportedTotal, records.count),
                title: title,
                url: url,
                thumbnailURL: thumbnailURL,
                duration: duration,
                isSelected: true,
                status: .pending
            ))
        }

        guard !items.isEmpty else { throw CollectionMetadataError.malformedOutput }
        items.sort { $0.index < $1.index }
        return CollectionPreview(sourceURL: sourceURL, title: collectionTitle, items: items)
    }

    private static func string(in record: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func integer(in record: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = record[key] as? NSNumber { return value.intValue }
            if let value = record[key] as? String, let integer = Int(value) { return integer }
        }
        return nil
    }

    private static func number(in record: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = record[key] as? NSNumber { return value.doubleValue }
            if let value = record[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    private static func secureURL(from value: String?) -> URL? {
        guard var value else { return nil }
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        } else if value.hasPrefix("//") {
            value = "https:" + value
        }
        return URL(string: value)
    }

    private static func conciseTitle(_ rawTitle: String, collectionTitle: String, index: Int) -> String {
        var value = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(collectionTitle) {
            value.removeFirst(collectionTitle.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let expression = try? NSRegularExpression(pattern: "^[pP]0*\(index)\\s*[-—_:：]?\\s*"),
           let match = expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
           ),
           let range = Range(match.range, in: value) {
            value.removeSubrange(range)
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return FilenameSanitizer.component(value.isEmpty ? rawTitle : value, fallback: "第 \(index) 集")
    }
}

enum BilibiliViewMetadataParser {
    private struct Response: Decodable {
        let code: Int
        let message: String?
        let data: Video?
    }

    private struct Video: Decodable {
        let bvid: String?
        let title: String
        let pic: String?
        let pages: [Page]
    }

    private struct Page: Decodable {
        let page: Int
        let part: String
        let duration: Double?
        let firstFrame: String?

        enum CodingKeys: String, CodingKey {
            case page, part, duration
            case firstFrame = "first_frame"
        }
    }

    static func parse(data: Data, sourceURL: URL) throws -> CollectionPreview {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == 0, let video = response.data, !video.pages.isEmpty else {
            let reason = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "BiliFetch.BilibiliViewMetadataParser",
                code: response.code,
                userInfo: [NSLocalizedDescriptionKey: reason?.isEmpty == false ? reason! : "B站未返回视频分集信息。"]
            )
        }

        let collectionTitle = FilenameSanitizer.component(video.title, fallback: "B站合集")
        let bvid = video.bvid ?? URLClassifier.bvid(from: sourceURL) ?? "BVUnknown"
        let total = video.pages.count
        let defaultThumbnail = secureURL(from: video.pic)
        let items = video.pages.map { page in
            let title = FilenameSanitizer.component(page.part, fallback: "第 \(page.page) 集")
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.bilibili.com"
            components.path = "/video/\(bvid)"
            components.queryItems = [URLQueryItem(name: "p", value: String(page.page))]
            let pageURL = components.url ?? sourceURL

            return CollectionItem(
                id: "\(bvid)_p\(page.page)",
                index: page.page,
                total: total,
                title: title,
                url: pageURL,
                thumbnailURL: secureURL(from: page.firstFrame) ?? defaultThumbnail,
                duration: page.duration,
                isSelected: true,
                status: .pending
            )
        }.sorted { $0.index < $1.index }

        return CollectionPreview(sourceURL: sourceURL, title: collectionTitle, items: items)
    }

    private static func secureURL(from value: String?) -> URL? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        } else if value.hasPrefix("//") {
            value = "https:" + value
        }
        return URL(string: value)
    }
}
