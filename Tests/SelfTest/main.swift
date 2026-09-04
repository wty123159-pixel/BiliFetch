import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        failures += 1
        print("✗ \(message)")
    }
}

check(
    URLClassifier.validatedURL(from: "https://www.bilibili.com/video/BV123") != nil,
    "accepts bilibili video URLs"
)
check(
    URLClassifier.validatedURL(from: "https://b23.tv/example") != nil,
    "accepts b23.tv short URLs"
)
check(
    URLClassifier.validatedURL(from: "https://bilibili.com.evil.example/video/BV123") == nil,
    "rejects lookalike hosts"
)

let videoURL = URL(string: "https://www.bilibili.com/video/BV123")!
let collectionURL = URL(string: "https://space.bilibili.com/12/lists/34?type=season")!
let collectionContextVideoURL = URL(
    string: "https://www.bilibili.com/video/BV123?spm_id_from=333.788.videopod.sections"
)!
check(!DownloadScope.automatic.downloadsPlaylist(for: videoURL), "ordinary BV links resolve to current video")
check(DownloadScope.automatic.downloadsPlaylist(for: collectionURL), "collection links resolve to collections")
check(
    URLClassifier.hasOuterCollectionContext(collectionContextVideoURL),
    "recognizes collection context carried by a BV video link"
)
check(
    DownloadScope.automatic.downloadsPlaylist(for: collectionContextVideoURL),
    "BV links opened from a collection keep playlist resolution enabled"
)
check(
    !URLClassifier.hasOuterCollectionContext(videoURL),
    "does not misclassify an ordinary BV link as an outer collection"
)
check(
    DownloadScope.automatic.downloadsPlaylist(
        for: URL(string: "https://www.bilibili.com/video/BV123?p=2")!
    ),
    "multi-part BV links automatically resolve to collections"
)

let request = DownloadRequest(
    url: videoURL,
    destination: URL(fileURLWithPath: "/tmp/Bili Fetch"),
    scope: .current,
    quality: .p1080,
    cookies: .safari,
    includeSubtitles: true,
    engine: .aria2,
    outputTemplate: "[02] 测试 [%(id)s].%(ext)s",
    cookieFileURL: URL(fileURLWithPath: "/tmp/bilibili-cookies.txt")
)
let arguments = DownloadArgumentBuilder.arguments(
    for: request,
    ffmpegPath: "/tmp/ffmpeg",
    aria2Path: "/tmp/aria2c"
)
check(arguments.suffix(2).first == "--", "terminates options before the user URL")
check(arguments.last == videoURL.absoluteString, "keeps the URL as one Process argument")
check(arguments.contains("--no-playlist"), "individual collection items disable playlists")
check(arguments.contains("--downloader"), "enables aria2")
check(arguments.contains("--continue"), "keeps yt-dlp partial files resumable")
check(arguments.contains("--part"), "writes incomplete downloads to explicit part files")
check(arguments.contains(where: { $0.contains("--continue=true") }), "enables aria2 continuation")
check(
    !arguments.contains(where: { $0.contains("-c true") }),
    "does not pass aria2's optional continue value as a separate URI"
)
check(arguments.contains(where: { $0.contains("-x 8") }), "uses eight aria2 connections")
check(arguments.contains(where: { $0.contains("--auto-file-renaming=false") }), "reuses the original aria2 partial filename")
check(arguments.contains(where: { $0.contains("--all-proxy=") }), "aria2 media bypasses incompatible proxies")
check(arguments.contains(where: { $0.contains("--summary-interval=0") }), "suppresses aria2 progress-summary spam")
check(arguments.contains(where: { $0.contains("--show-console-readout=true") }), "keeps aria2 percentage and speed available to the UI")
check(!arguments.contains(where: { $0.contains("--quiet=true") }), "does not hide aria2 live progress")
check(!arguments.contains("--proxy"), "metadata extraction keeps the system network route")
check(arguments.contains("[02] 测试 [%(id)s].%(ext)s"), "uses the precomputed collection filename")
check(arguments.contains(where: { $0.contains("[width<=1080]") }), "supports portrait episodes in bounded quality modes")
check(arguments.contains("--cookies"), "prefers cookies captured by the in-app login")
check(arguments.contains("/tmp/bilibili-cookies.txt"), "passes the in-app cookie file")
check(arguments.contains("mp4"), "uses the MP4 muxer included with the bundled FFmpeg")
check(!arguments.contains("mp4/mkv"), "does not select the unavailable bundled MKV muxer")
check(
    DownloadCompletionEvaluator.succeeded(exitCode: 1, hasCompletedVideo: true),
    "treats a verified output video as completed even when a trailing tool exits nonzero"
)
check(
    !DownloadCompletionEvaluator.succeeded(exitCode: 1, hasCompletedVideo: false),
    "keeps genuine failed downloads marked as failed"
)
check(
    !DownloadCompletionEvaluator.succeeded(exitCode: 0, hasCompletedVideo: false),
    "does not accept a clean process exit without a verified final video"
)
check(
    !DownloadOutputValidationPolicy.isPlausibleFinalVideoFileName("episode.f30106.mp4"),
    "rejects a video-only yt-dlp format file as a final output"
)
check(
    !DownloadOutputValidationPolicy.isPlausibleFinalVideoFileName("episode.mp4.part"),
    "rejects an incomplete part file as a final output"
)
check(
    DownloadOutputValidationPolicy.isPlausibleFinalVideoFileName("episode.mp4"),
    "accepts a merged video filename for stream verification"
)
check((1...3).allSatisfy(DownloadRetryPolicy.shouldRetry), "retries each failed download three times")
check(!DownloadRetryPolicy.shouldRetry(afterAttempt: 4), "marks the fourth failed attempt as permanent")
check(DownloadConcurrencyPolicy.clamped(0) == 1, "keeps at least one concurrent download")
check(DownloadConcurrencyPolicy.clamped(9) == 5, "caps concurrent downloads at five")
check(
    DownloadResumePolicy.shouldAutoResume(
        wasPausedForSystemSleep: true,
        isDownloading: true,
        isPaused: true
    ),
    "automatically resumes a task paused by system sleep"
)
check(
    !DownloadResumePolicy.shouldAutoResume(
        wasPausedForSystemSleep: false,
        isDownloading: true,
        isPaused: true
    ),
    "does not automatically resume a manually paused task"
)
check(
    DownloadResidualFilePolicy.belongsToCompletedFile(
        residualFileName: "[01] 第一集 [BVdemo_p1].mp4.part.aria2",
        completedFileName: "[01] 第一集 [BVdemo_p1].mp4"
    ),
    "cleans an aria2 control file only after its final video exists"
)
check(
    DownloadResidualFilePolicy.belongsToCompletedFile(
        residualFileName: "[01] 第一集 [BVdemo_p1].f137.mp4.part",
        completedFileName: "[01] 第一集 [BVdemo_p1].mkv"
    ),
    "cleans a matching intermediate part file across merge containers"
)
check(
    !DownloadResidualFilePolicy.belongsToCompletedFile(
        residualFileName: "[02] 第二集 [BVdemo_p2].mp4.part",
        completedFileName: "[01] 第一集 [BVdemo_p1].mp4"
    ),
    "keeps a partial file that does not belong to the verified video"
)
check(
    !DownloadResidualFilePolicy.isResidualFile("[01] 第一集 [BVdemo_p1].mp4"),
    "never classifies a final video as a residual file"
)

let nativeArguments = DownloadArgumentBuilder.arguments(
    for: DownloadRequest(
        url: videoURL,
        destination: URL(fileURLWithPath: "/tmp"),
        scope: .current,
        quality: .best,
        cookies: .none,
        includeSubtitles: false,
        engine: .native,
        outputTemplate: nil,
        cookieFileURL: nil
    ),
    ffmpegPath: nil,
    aria2Path: "/tmp/aria2c"
)
check(!nativeArguments.contains("--downloader"), "standard mode does not invoke aria2")
check(nativeArguments.contains("bv*+ba/b"), "uses a DASH fallback without ffmpeg")

let metadataLines = [
    #"{"id":"BVdemo_p1","title":"演示合集 p01 第一章","webpage_url":"https://www.bilibili.com/video/BVdemo?p=1","thumbnail":"http://i1.hdslb.com/a.jpg","duration":61,"playlist_title":"演示合集","playlist_index":1,"playlist_count":2}"#,
    #"{"id":"BVdemo_p2","title":"演示合集 p02 第二章","webpage_url":"https://www.bilibili.com/video/BVdemo?p=2","thumbnail":"//i1.hdslb.com/b.jpg","duration":125,"playlist_title":"演示合集","playlist_index":2,"playlist_count":2}"#
]

do {
    let preview = try CollectionMetadataParser.parse(lines: metadataLines, sourceURL: videoURL)
    check(preview.title == "演示合集", "parses the collection title")
    check(preview.items.count == 2, "parses all collection items")
    check(preview.items[0].title == "第一章", "removes repeated collection prefixes from item titles")
    check(preview.items[1].thumbnailURL?.scheme == "https", "upgrades cover URLs to HTTPS")
    check(preview.items[1].durationText == "2:05", "formats durations")
} catch {
    check(false, "parses collection metadata: \(error.localizedDescription)")
}

do {
    let binaryPlanJSON = #"{"formatVersion":1,"platform":"macos","fromVersion":"1.5.6","toVersion":"1.5.7","files":[{"path":"Contents/MacOS/BiliFetch","sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","size":12,"mode":493,"patch":{"source":"patches/000001.bin","baseSha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","baseSize":20,"dataSha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","dataSize":4,"operations":[{"type":"copy","offset":0,"length":8},{"type":"data","offset":0,"length":4}]}}],"deletePaths":[]}"#.data(using: .utf8)!
    let plan = try JSONDecoder().decode(AppDeltaPlan.self, from: binaryPlanJSON)
    try plan.validate(currentVersion: "1.5.6", targetVersion: "1.5.7")
    check(plan.files.first?.patch?.operations.count == 2, "accepts a bounded macOS binary delta plan")
} catch {
    check(false, "validates a macOS binary delta plan: \(error.localizedDescription)")
}

let bilibiliViewJSON = #"{"code":0,"message":"0","data":{"bvid":"BVdemo","title":"API 分集","pic":"http://i0.hdslb.com/main.jpg","pages":[{"page":1,"part":"第一集","duration":61,"first_frame":"//i0.hdslb.com/first.jpg"},{"page":2,"part":"第二集","duration":125,"first_frame":""}]}}"#.data(using: .utf8)!

do {
    let preview = try BilibiliViewMetadataParser.parse(data: bilibiliViewJSON, sourceURL: videoURL)
    check(preview.items.count == 2, "parses every page returned by the Bilibili view API")
    check(preview.items.allSatisfy(\.isSelected), "selects API-discovered pages by default")
    check(preview.items[0].thumbnailURL?.scheme == "https", "uses secure per-page thumbnails")
    check(preview.items[1].thumbnailURL?.absoluteString.contains("main.jpg") == true, "falls back to the main cover")
    check(preview.items[1].url.absoluteString.contains("p=2"), "creates canonical per-page download URLs")
} catch {
    check(false, "parses Bilibili view metadata: \(error.localizedDescription)")
}

let bilibiliUGCSeasonJSON = #"{"code":0,"message":"0","data":{"bvid":"BVseason01","title":"当前视频","pic":"http://i0.hdslb.com/main.jpg","pages":[{"page":1,"part":"当前视频","duration":61,"first_frame":""}],"ugc_season":{"title":"完整 UGC 合集","cover":"http://i0.hdslb.com/season.jpg","sections":[{"episodes":[{"bvid":"BVseason01","title":"合集第一集","arc":{"pic":"http://i1.hdslb.com/one.jpg","duration":61}},{"bvid":"BVseason02","title":"合集第二集","arc":{"pic":"http://i2.hdslb.com/two.jpg","duration":125}}]}]}}}"#.data(using: .utf8)!

do {
    let preview = try BilibiliViewMetadataParser.parse(data: bilibiliUGCSeasonJSON, sourceURL: videoURL)
    check(preview.title == "完整 UGC 合集", "uses the outer UGC collection title")
    check(preview.items.count == 2, "expands every BV from the outer UGC collection")
    check(preview.items[1].title == "合集第二集", "uses each UGC episode title")
    check(preview.items[1].url.absoluteString.contains("BVseason02"), "creates a download URL for each UGC episode")
    check(preview.items[1].thumbnailURL?.scheme == "https", "normalizes UGC episode thumbnails")
} catch {
    check(false, "parses outer UGC collection metadata: \(error.localizedDescription)")
}

let nestedCollectionJSON = #"{"code":0,"message":"0","data":{"bvid":"BVnested","title":"当前多P合集","pic":"http://i0.hdslb.com/main.jpg","pages":[{"page":1,"part":"分P一","duration":61,"first_frame":""},{"page":2,"part":"分P二","duration":62,"first_frame":""}],"ugc_season":{"title":"外层合集","cover":"http://i0.hdslb.com/season.jpg","sections":[{"episodes":[{"bvid":"BVnested","title":"外层第一集"},{"bvid":"BVother","title":"外层第二集"}]}]}}}"#.data(using: .utf8)!

do {
    let preview = try BilibiliViewMetadataParser.parse(data: nestedCollectionJSON, sourceURL: videoURL)
    check(preview.title == "当前多P合集", "prefers the opened BV's internal parts over its outer UGC season")
    check(preview.items.count == 2, "keeps every internal part when a BV also belongs to an outer collection")
    check(preview.items[1].url.absoluteString.contains("p=2"), "keeps canonical part URLs for nested collections")
} catch {
    check(false, "prioritizes a multi-part BV over its outer collection: \(error.localizedDescription)")
}

let mixedContainerLines = (1...28).map { index in
    let container = index.isMultiple(of: 2) ? "mp4" : "flv"
    return #"{"id":"mixed_\#(index)","title":"第 \#(index) 集","webpage_url":"https://www.bilibili.com/video/BVmixed?p=\#(index)","playlist_title":"混合格式合集","playlist_index":\#(index),"playlist_count":28,"ext":"\#(container)"}"#
}

do {
    let preview = try CollectionMetadataParser.parse(lines: mixedContainerLines, sourceURL: videoURL)
    check(preview.items.count == 28, "keeps all 28 mixed FLV/MP4 collection entries")
    check(preview.items.allSatisfy(\.isSelected), "selects every mixed-format entry by default")
} catch {
    check(false, "parses a 28-item mixed-format collection: \(error.localizedDescription)")
}

check(
    FilenameSanitizer.collectionOutputTemplate(index: 3, total: 120, title: "A/B 50%")
        == "[003] A B 50%% [%(id)s].%(ext)s",
    "creates safe, zero-padded filenames"
)

do {
    let newerComparison = try AppVersion.compare("1.5.7", "1.5.6")
    let equalComparison = try AppVersion.compare("v1.5.7", "1.5.7")
    check(newerComparison == .orderedDescending, "detects a newer macOS version")
    check(equalComparison == .orderedSame, "accepts an optional version prefix")
    let updateJSON = #"{"schemaVersion":2,"version":"1.1.0","notes":"同步更新","windows":{"url":"https://example.com/win.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":100},"macos":{"version":"1.5.7","url":"https://example.com/mac.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":200,"deltas":[{"fromVersion":"1.5.6","url":"https://example.com/mac-delta.zip","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":20}]}}"#.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: updateJSON)
    let release = try manifest.macOSRelease(currentVersion: "1.5.6")
    check(release.version == "1.5.7", "reads the platform-specific macOS version")
    check(release.url.scheme == "https", "requires an HTTPS macOS update package")
    check(release.sha256.count == 64, "requires a full macOS SHA-256")
    check(release.delta?.fromVersion == "1.5.6", "selects an exact-version macOS delta")
    check(release.preferredAsset.kind == .delta, "prefers a matching incremental package")
    let fallback = try manifest.macOSRelease(currentVersion: "1.5.5")
    check(fallback.delta == nil && fallback.preferredAsset.kind == .full, "falls back to the full package without an exact delta")
} catch {
    check(false, "parses the shared cross-platform update manifest: \(error.localizedDescription)")
}

do {
    let plan = AppDeltaPlan(
        formatVersion: 1,
        platform: "macos",
        fromVersion: "1.5.6",
        toVersion: "1.5.7",
        files: [.init(path: "Contents/MacOS/BiliFetch", sha256: String(repeating: "d", count: 64), size: 10, mode: 0o755, patch: nil)],
        deletePaths: ["Contents/Resources/obsolete.txt"]
    )
    try plan.validate(currentVersion: "1.5.6", targetVersion: "1.5.7")
    check(true, "accepts a safe macOS delta file plan")
    check(!AppDeltaPlan.isSafeRelativePath("../outside"), "rejects incremental path traversal")
} catch {
    check(false, "validates a safe macOS delta file plan: \(error.localizedDescription)")
}

do {
    let invalidJSON = #"{"version":"1.1.0","macos":{"version":"1.5.7","url":"http://example.com/mac.zip","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}"#.data(using: .utf8)!
    let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: invalidJSON)
    _ = try manifest.macOSRelease()
    check(false, "rejects an insecure macOS update URL")
} catch {
    check(true, "rejects an insecure macOS update URL")
}

if let transfer = UpdateProgressParser.aria2("[#abc 80MiB/200MiB(40%) CN:8 DL:12MiB]") {
    check(transfer.fraction == 0.4, "parses accelerated update percentage")
    check(transfer.speed == "12MiB/s", "parses accelerated update speed")
} else {
    check(false, "parses accelerated update progress")
}

let callbackQueue = DispatchQueue(label: "BiliFetch.SelfTest.ProcessRunner")
let runner = ProcessRunner(callbackQueue: callbackQueue)

func runProcess(_ executable: String, arguments: [String]) -> (Int32?, [String]) {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32?
    var lines: [String] = []
    do {
        try runner.start(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            onLine: { line, _ in lines.append(line) },
            onFinish: { exitCode in
                code = exitCode
                semaphore.signal()
            }
        )
    } catch {
        return (nil, [error.localizedDescription])
    }
    guard semaphore.wait(timeout: .now() + 5) == .success else { return (nil, ["timeout"]) }
    return (code, lines)
}

let failedRun = runProcess("/usr/bin/false", arguments: [])
check(failedRun.0 != nil && failedRun.0 != 0, "observes a failed process")
let recoveredRun = runProcess("/bin/echo", arguments: ["recovered"])
check(recoveredRun.0 == 0, "starts a new process after failure")
check(recoveredRun.1.contains("recovered"), "receives output after failure without a deadlock")

let concurrentQueue = DispatchQueue(label: "BiliFetch.SelfTest.Concurrent", attributes: .concurrent)
let concurrentGroup = DispatchGroup()
var concurrentCodes: [Int32] = []
let concurrentLock = NSLock()
var concurrentRunners: [ProcessRunner] = []
for _ in 1...5 {
    let concurrentRunner = ProcessRunner(callbackQueue: concurrentQueue)
    concurrentRunners.append(concurrentRunner)
    concurrentGroup.enter()
    do {
        try concurrentRunner.start(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0.1"],
            onLine: { _, _ in },
            onFinish: { code in
                concurrentLock.lock()
                concurrentCodes.append(code)
                concurrentLock.unlock()
                concurrentGroup.leave()
            }
        )
    } catch {
        concurrentGroup.leave()
    }
}
check(concurrentGroup.wait(timeout: .now() + 5) == .success, "runs five download processes concurrently")
check(concurrentCodes.count == 5 && concurrentCodes.allSatisfy { $0 == 0 }, "finishes all concurrent processes independently")

if failures > 0 {
    print("\n\(failures) self-test(s) failed")
    exit(1)
}

print("\nAll BiliFetch self-tests passed")
