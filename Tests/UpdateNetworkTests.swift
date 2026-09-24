import Foundation

private final class FixtureProtocol: URLProtocol {
    static var live = false
    static var urls: [URL] = []
    static var metadata: String = ""
    static var manifest: String = ""
    override class func canInit(with request: URLRequest) -> Bool { !live || request.url?.host == "github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.urls.append(url)
        if url.host == "github.com" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let asset = url.path.contains("/assets/")
        if asset && request.value(forHTTPHeaderField: "Accept") != "application/octet-stream" {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((asset ? Self.manifest : Self.metadata).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct UpdateNetworkTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://github.com/wty123159-pixel/BiliFetch/releases/latest/download/update.json")!
        let prefix = "https://api.github.com/repos/wty123159-pixel/BiliFetch/releases"
        FixtureProtocol.metadata = """
        {"tag_name":"v1","draft":false,"assets":[{"name":"update.json","id":123,"state":"uploaded","url":"\(prefix)/assets/123"}]}
        """
        FixtureProtocol.manifest = """
        {"macos":{"version":"1.5.17","url":"https://example.test/app.zip","sha256":"\(String(repeating: "a", count: 64))","notes":"fixture"}}
        """
        let network = UpdateNetwork(userAgent: "BiliFetch-Tests", session: session)
        let first = try await network.manifest(url, currentVersion: "1.5.16")
        precondition(first.version == "1.5.17")
        precondition(FixtureProtocol.urls.map(\.host) == ["github.com", "api.github.com", "api.github.com"])
        FixtureProtocol.urls = []
        _ = try await network.manifest(url, currentVersion: "1.5.16")
        precondition(FixtureProtocol.urls.map(\.path) == ["/repos/wty123159-pixel/BiliFetch/releases/assets/123"])
        print("PASS: blocked primary, official API asset, correct headers, cached metadata and preferred route")
        let integrityNetwork = UpdateNetwork(userAgent: "BiliFetch-Tests", session: session)
        var routes: [Bool] = []
        _ = try await integrityNetwork.withFallback(url) { source in
            routes.append(source.officialAPI)
            if !source.officialAPI { throw URLError(.cannotDecodeContentData) }
            return true
        }
        precondition(routes == [false, true])
        print("PASS: failed package integrity can retry the independent official route")
        FixtureProtocol.metadata = FixtureProtocol.metadata.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
        do {
            _ = try await UpdateNetwork(userAgent: "BiliFetch-Tests", session: session).manifest(url, currentVersion: "1.5.16")
            fatalError("draft unexpectedly accepted")
        } catch { print("PASS: both routes fail safely when release is unavailable") }
        if CommandLine.arguments.contains("--live") {
            FixtureProtocol.live = true
            let release = try await UpdateNetwork(userAgent: "BiliFetch-Tests", session: session).manifest(url, currentVersion: "1.5.13")
            print("PASS: real Swift URLSession official API fallback with proxy disabled; macOS release \(release.version)")
        }
    }
}
