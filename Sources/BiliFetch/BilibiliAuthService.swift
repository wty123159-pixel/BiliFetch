import Foundation

struct BilibiliQRCode: Equatable {
    let key: String
    let loginURL: URL
}

enum BilibiliQRCodePollResult: Equatable {
    case waitingForScan
    case waitingForConfirmation
    case expired
    case authenticated
}

enum BilibiliAuthError: LocalizedError {
    case invalidResponse
    case service(String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "B 站登录接口返回了无法识别的数据，请稍后重试。"
        case .service(let message):
            return message.isEmpty ? "B 站登录服务暂时不可用，请稍后重试。" : message
        case .missingSession:
            return "登录已确认，但未收到有效会话，请刷新二维码重试。"
        }
    }
}

@MainActor
final class BilibiliAuthService {
    static var cookieFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BiliFetch/Cookies", isDirectory: true)
            .appendingPathComponent("bilibili.txt")
    }

    private static let generateURL = URL(
        string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source=main-fe-header"
    )!
    private static let pollBaseURL = URL(
        string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
    )!
    private static let loginPageURL = URL(string: "https://passport.bilibili.com/login")!
    private static let allowedCookieNames = Set([
        "SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"
    ])

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func refreshStatus(completion: @escaping (Bool) -> Void) {
        completion(Self.hasActiveSessionInCookieFile())
    }

    func generateQRCode(completion: @escaping (Result<BilibiliQRCode, Error>) -> Void) {
        let request = Self.request(url: Self.generateURL)
        session.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data,
                      let response = try? JSONDecoder().decode(GenerateResponse.self, from: data),
                      response.code == 0,
                      let payload = response.data,
                      let loginURL = URL(string: payload.url),
                      !payload.qrcodeKey.isEmpty else {
                    completion(.failure(BilibiliAuthError.invalidResponse))
                    return
                }
                completion(.success(BilibiliQRCode(key: payload.qrcodeKey, loginURL: loginURL)))
            }
        }.resume()
    }

    func pollQRCode(
        key: String,
        completion: @escaping (Result<BilibiliQRCodePollResult, Error>) -> Void
    ) {
        var components = URLComponents(url: Self.pollBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "qrcode_key", value: key),
            URLQueryItem(name: "source", value: "main-fe-header")
        ]
        guard let url = components.url else {
            completion(.failure(BilibiliAuthError.invalidResponse))
            return
        }

        let request = Self.request(url: url)
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data,
                      let payload = try? JSONDecoder().decode(PollResponse.self, from: data),
                      payload.code == 0,
                      let status = payload.data else {
                    completion(.failure(BilibiliAuthError.invalidResponse))
                    return
                }

                switch status.code {
                case 86101:
                    completion(.success(.waitingForScan))
                case 86090:
                    completion(.success(.waitingForConfirmation))
                case 86038:
                    completion(.success(.expired))
                case 0:
                    do {
                        let cookies = Self.loginCookies(
                            callbackURLText: status.url,
                            response: response as? HTTPURLResponse
                        )
                        guard Self.hasActiveSession(in: cookies) else {
                            throw BilibiliAuthError.missingSession
                        }
                        try Self.writeCookieFile(cookies)
                        completion(.success(.authenticated))
                    } catch {
                        completion(.failure(error))
                    }
                default:
                    completion(.failure(BilibiliAuthError.service(status.message)))
                }
            }
        }.resume()
    }

    func logOut(completion: @escaping () -> Void) {
        try? FileManager.default.removeItem(at: Self.cookieFileURL)
        completion()
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.6 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(loginPageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return request
    }

    private static func loginCookies(
        callbackURLText: String,
        response: HTTPURLResponse?
    ) -> [HTTPCookie] {
        var cookiesByName: [String: HTTPCookie] = [:]

        if let response {
            let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            let responseCookies = HTTPCookie.cookies(
                withResponseHeaderFields: fields,
                for: response.url ?? loginPageURL
            )
            for cookie in responseCookies where isBilibiliCookie(cookie) {
                cookiesByName[cookie.name] = cookie
            }
        }

        if let callbackURL = URL(string: callbackURLText),
           let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems where allowedCookieNames.contains(item.name) {
                guard let value = item.value, !value.isEmpty,
                      let cookie = HTTPCookie(properties: [
                        .domain: ".bilibili.com",
                        .path: "/",
                        .name: item.name,
                        .value: value,
                        .secure: "TRUE",
                        .expires: Date().addingTimeInterval(180 * 24 * 60 * 60)
                      ]) else { continue }
                if cookiesByName[item.name] == nil {
                    cookiesByName[item.name] = cookie
                }
            }
        }

        return Array(cookiesByName.values)
    }

    private static func hasActiveSessionInCookieFile() -> Bool {
        guard let text = try? String(contentsOf: cookieFileURL, encoding: .utf8) else { return false }
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7, fields[5] == "SESSDATA", !fields[6].isEmpty else { continue }
            let expiration = TimeInterval(fields[4]) ?? 0
            return expiration == 0 || Date(timeIntervalSince1970: expiration) > Date()
        }
        return false
    }

    private static func hasActiveSession(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            cookie.name == "SESSDATA" &&
            !cookie.value.isEmpty &&
            (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
    }

    private static func isBilibiliCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
    }

    private static func writeCookieFile(_ cookies: [HTTPCookie]) throws {
        let fileURL = cookieFileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = netscapeCookieFile(from: cookies)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func netscapeCookieFile(from cookies: [HTTPCookie]) -> String {
        var lines = [
            "# Netscape HTTP Cookie File",
            "# Generated by BiliFetch after Bilibili QR login confirmation.",
            ""
        ]

        for cookie in cookies.sorted(by: { ($0.domain, $0.name) < ($1.domain, $1.name) }) {
            guard cookie.expiresDate == nil || cookie.expiresDate! > Date() else { continue }
            var domain = cookie.domain
            if cookie.isHTTPOnly { domain = "#HttpOnly_" + domain }
            let includeSubdomains = cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expires = Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)
            let name = cookie.name.replacingOccurrences(of: "\t", with: "")
            let value = cookie.value.replacingOccurrences(of: "\t", with: "")
            lines.append(
                [domain, includeSubdomains, cookie.path, secure, String(expires), name, value]
                    .joined(separator: "\t")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct GenerateResponse: Decodable {
    let code: Int
    let message: String
    let data: Payload?

    struct Payload: Decodable {
        let url: String
        let qrcodeKey: String

        enum CodingKeys: String, CodingKey {
            case url
            case qrcodeKey = "qrcode_key"
        }
    }
}

private struct PollResponse: Decodable {
    let code: Int
    let message: String
    let data: Payload?

    struct Payload: Decodable {
        let url: String
        let refreshToken: String
        let timestamp: Int
        let code: Int
        let message: String

        enum CodingKeys: String, CodingKey {
            case url
            case refreshToken = "refresh_token"
            case timestamp
            case code
            case message
        }
    }
}
