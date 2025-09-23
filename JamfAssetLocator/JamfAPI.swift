//
//  JamfAPI.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import Foundation

enum JamfAPIError: Error, CustomStringConvertible {
    case invalidConfig
    case authFailed(status: Int?, body: String?)
    case badResponse(status: Int?, body: String?)
    case transport(Error)

    var description: String {
        switch self {
        case .invalidConfig:
            return "Invalid configuration"
        case let .authFailed(status, body):
            return "Auth failed" + JamfAPI.describe(status: status, body: body)
        case let .badResponse(status, body):
            return "Bad response" + JamfAPI.describe(status: status, body: body)
        case let .transport(err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

struct JamfAPI {
    let baseURL: URL

    // Legacy user/pass (Classic API)
    let username: String?
    let password: String?

    // OAuth Client Credentials (modern API)
    let clientID: String?
    let clientSecret: String?

    // Runtime logging toggle (set true to force logs in any build)
    private static let verboseLogging: Bool = true

    // Unique build/runtime signature for diagnostics
    private static let buildSignature: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let ts = formatter.string(from: Date())
        return "JamfAPI.swift signature: \(ts)"
    }()

    // MARK: - In-memory token caches (no Keychain)
    private static let expirySkew: TimeInterval = 60

    // OAuth (/api/oauth/token) cache
    private var oauthToken: String?
    private var oauthExpiry: Date?
    private var oauthFetchTask: Task<(token: String, expiry: Date), Error>?

    // Classic (/api/v1/auth/token) cache
    private var classicToken: String?
    private var classicExpiry: Date?
    private var classicFetchTask: Task<(token: String, expiry: Date), Error>?

    init?(config: ManagedConfig) {
        if Self.shouldLog() {
            print(Self.buildSignature)
        }

        guard let urlStr = config.jamfURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else {
            if Self.verboseLogging {
                print("JamfAPI.init: invalid config (missing or invalid JAMF_URL)")
            }
            return nil
        }
        self.baseURL = url

        // OAuth client credentials
        let rawClientID = config.jamfClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawClientSecret = config.jamfClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = rawClientID?.nilIfEmpty
        self.clientSecret = rawClientSecret?.nilIfEmpty

        // Classic username/password
        let rawUsername = config.jamfUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPassword = config.jamfPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = rawUsername?.nilIfEmpty
        self.password = rawPassword?.nilIfEmpty

        if Self.verboseLogging {
            let hasOAuthID = (self.clientID != nil)
            let hasOAuthSecret = (self.clientSecret != nil)
            let hasUser = (self.username != nil)
            let hasPass = (self.password != nil)
            print("JamfAPI.init: URL ok. OAuth(clientID:\(hasOAuthID), clientSecret:\(hasOAuthSecret)) Classic(username:\(hasUser), password:\(hasPass))")
        }

        let oauthComplete = (self.clientID != nil && self.clientSecret != nil)
        let classicComplete = (self.username != nil && self.password != nil)

        if !oauthComplete && !classicComplete {
            if Self.verboseLogging {
                var reasons: [String] = []
                if !(self.clientID != nil) { reasons.append("missing clientID") }
                if !(self.clientSecret != nil) { reasons.append("missing clientSecret") }
                if !(self.username != nil) { reasons.append("missing username") }
                if !(self.password != nil) { reasons.append("missing password") }
                print("JamfAPI.init: invalid config, neither OAuth nor Classic complete. Missing: \(reasons.joined(separator: ", "))")
            }
            return nil
        }
    }

    // Convenience to know if modern OAuth is available
    private var hasOAuth: Bool { clientID != nil && clientSecret != nil }

    // MARK: - OAuth (modern /api endpoints)

    func fetchOAuthToken() async throws -> String {
        guard let clientID, let clientSecret else {
            throw JamfAPIError.invalidConfig
        }
        do {
            return try await fetchOAuthTokenFormBody(clientID: clientID, clientSecret: clientSecret)
        } catch {
            return try await fetchOAuthTokenBasic(clientID: clientID, clientSecret: clientSecret)
        }
    }

    private mutating func validOAuthToken() async throws -> String {
        if let token = oauthToken, let expiry = oauthExpiry, Date() < expiry.addingTimeInterval(-Self.expirySkew) {
            return token
        }

        if let task = oauthFetchTask {
            let result = try await task.value
            setOAuthCache(token: result.token, expiry: result.expiry)
            return result.token
        }

        let baseURL = self.baseURL
        let clientID = self.clientID
        let clientSecret = self.clientSecret

        let task = Task<(token: String, expiry: Date), Error> {
            let raw = try await JamfAPI.fetchOAuthToken(baseURL: baseURL, clientID: clientID, clientSecret: clientSecret)
            let expiry = Date().addingTimeInterval(25 * 60)
            return (raw, expiry)
        }
        oauthFetchTask = task
        defer { oauthFetchTask = nil }

        let result = try await task.value
        setOAuthCache(token: result.token, expiry: result.expiry)
        return result.token
    }

    private mutating func setOAuthCache(token: String, expiry: Date) {
        self.oauthToken = token
        self.oauthExpiry = expiry
    }

    private static func fetchOAuthToken(baseURL: URL, clientID: String?, clientSecret: String?) async throws -> String {
        guard let clientID, let clientSecret else {
            throw JamfAPIError.invalidConfig
        }
        do {
            return try await fetchOAuthTokenFormBody(baseURL: baseURL, clientID: clientID, clientSecret: clientSecret)
        } catch {
            return try await fetchOAuthTokenBasic(baseURL: baseURL, clientID: clientID, clientSecret: clientSecret)
        }
    }

    private func fetchOAuthTokenFormBody(clientID: String, clientSecret: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let bodyItems: [String: String] = [
            "grant_type": "client_credentials",
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        let bodyString = bodyItems
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            }
            .joined(separator: "&")
        req.httpBody = bodyString.data(using: .utf8)

        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        logRequest(req, bodyPreview: bodyString)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.authFailed(status: nil, body: "No HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["access_token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Missing 'access_token' key. Body: \(json)")
        }
    }

    private static func fetchOAuthTokenFormBody(baseURL: URL, clientID: String, clientSecret: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let bodyItems: [String: String] = [
            "grant_type": "client_credentials",
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        let bodyString = bodyItems
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            }
            .joined(separator: "&")
        req.httpBody = bodyString.data(using: .utf8)

        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        JamfAPI.logRequest(req, bodyPreview: bodyString)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.authFailed(status: nil, body: "No HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8)
            JamfAPI.logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["access_token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Missing 'access_token' key. Body: \(json)")
        }
    }

    private func fetchOAuthTokenBasic(clientID: String, clientSecret: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let body = "grant_type=client_credentials"
        req.httpBody = body.data(using: .utf8)

        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let loginString = "\(clientID):\(clientSecret)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw JamfAPIError.authFailed(status: nil, body: "Unable to encode client credentials")
        }
        let base64Login = loginData.base64EncodedString()
        req.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")

        logRequest(req, redacting: ["Authorization"], bodyPreview: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.authFailed(status: nil, body: "No HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["access_token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Missing 'access_token' key. Body: \(json)")
        }
    }

    private static func fetchOAuthTokenBasic(baseURL: URL, clientID: String, clientSecret: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/oauth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let body = "grant_type=client_credentials"
        req.httpBody = body.data(using: .utf8)

        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let loginString = "\(clientID):\(clientSecret)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw JamfAPIError.authFailed(status: nil, body: "Unable to encode client credentials")
        }
        let base64Login = loginData.base64EncodedString()
        req.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")

        JamfAPI.logRequest(req, redacting: ["Authorization"], bodyPreview: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.authFailed(status: nil, body: "No HTTP response")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8)
            JamfAPI.logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["access_token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: http.statusCode, body: "Missing 'access_token' key. Body: \(json)")
        }
    }

    // MARK: - Modern API models

    struct PagedResponse<T: Codable>: Codable {
        let totalCount: Int
        let results: [T]
    }

    struct Building: Codable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Department: Codable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct MobileDevice: Codable {
        struct Location: Codable {
            var username: String?
            var realName: String?
            var emailAddress: String?
            var position: String?
            var phoneNumber: String?
            var departmentId: String?
            var buildingId: String?
            var room: String?
        }
        var name: String?
        var assetTag: String?
        var siteId: String?
        var timeZone: String?
        var location: Location?
    }

    struct MobileDevicePatch: Codable {
        var name: String?
        var enforceName: Bool?
        var assetTag: String?
        var siteId: String?
        var timeZone: String?
        struct Location: Codable {
            var username: String?
            var realName: String?
            var emailAddress: String?
            var position: String?
            var phoneNumber: String?
            var departmentId: String?
            var buildingId: String?
            var room: String?
        }
        var location: Location?
    }

    // MARK: - Modern API helpers

    private mutating func authorizedModernRequest(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = req
        let token = try await validOAuthToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.badResponse(status: nil, body: "No HTTP response")
        }
        if (200...299).contains(http.statusCode) {
            if Self.shouldLog() {
                print("✅ \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "") -> \(http.statusCode)")
            }
        }
        if http.statusCode == 401 {
            if Self.shouldLog() {
                print("🔁 401 Unauthorized, re-auth and retry: \(req.url?.absoluteString ?? "")")
            }
            let _ = try await fetchOAuthToken()
            let token2 = try await validOAuthToken()
            var retry = req
            retry.setValue("Bearer \(token2)", forHTTPHeaderField: "Authorization")
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            guard let h2 = r2 as? HTTPURLResponse else {
                throw JamfAPIError.badResponse(status: nil, body: "No HTTP response (retry)")
            }
            if (200...299).contains(h2.statusCode) {
                if Self.shouldLog() {
                    print("✅ \(retry.httpMethod ?? "GET") \(retry.url?.absoluteString ?? "") -> \(h2.statusCode) (after retry)")
                }
            }
            return (d2, h2)
        }
        return (data, http)
    }

    // MARK: - Modern API calls

    mutating func getBuildingsModern(pageSize: Int = 100) async throws -> [Building] {
        var all: [Building] = []
        var page = 0
        while true {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/buildings"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "id:asc")
            ]
            guard let url = comps.url else { throw JamfAPIError.invalidConfig }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            logRequest(req)

            let (data, http) = try await authorizedModernRequest(req)
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                logBodyIfError(body)
                throw JamfAPIError.badResponse(status: http.statusCode, body: body)
            }
            let pageResp = try JSONDecoder().decode(PagedResponse<Building>.self, from: data)
            all.append(contentsOf: pageResp.results)
            if pageResp.results.count < pageSize || all.count >= pageResp.totalCount {
                break
            }
            page += 1
        }
        return all
    }

    mutating func getDepartmentsModern(pageSize: Int = 100) async throws -> [Department] {
        var all: [Department] = []
        var page = 0
        while true {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/departments"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "id:asc")
            ]
            guard let url = comps.url else { throw JamfAPIError.invalidConfig }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            logRequest(req)

            let (data, http) = try await authorizedModernRequest(req)
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                logBodyIfError(body)
                throw JamfAPIError.badResponse(status: http.statusCode, body: body)
            }
            let pageResp = try JSONDecoder().decode(PagedResponse<Department>.self, from: data)
            all.append(contentsOf: pageResp.results)
            if pageResp.results.count < pageSize || all.count >= pageResp.totalCount {
                break
            }
            page += 1
        }
        return all
    }

    mutating func getMobileDeviceModern(id: String) async throws -> MobileDevice {
        let url = baseURL.appendingPathComponent("/api/v2/mobile-devices/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        logRequest(req)

        let (data, http) = try await authorizedModernRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            logBodyIfError(body)
            throw JamfAPIError.badResponse(status: http.statusCode, body: body)
        }
        if Self.shouldLog() {
            print("📱 GET mobile device \(id) succeeded with status \(http.statusCode)")
        }
        return try JSONDecoder().decode(MobileDevice.self, from: data)
    }

    mutating func patchMobileDeviceModern(id: String, payload: MobileDevicePatch) async throws {
        let url = baseURL.appendingPathComponent("/api/v2/mobile-devices/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(payload)
        req.httpBody = body

        logRequest(req, bodyPreview: String(data: body, encoding: .utf8))

        let (data, http) = try await authorizedModernRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
        }
        if Self.shouldLog() {
            let respPreview = String(data: data, encoding: .utf8)
            if let respPreview, !respPreview.isEmpty {
                print("✅ PATCH mobile device \(id) succeeded with status \(http.statusCode). Response:\n\(respPreview)")
            } else {
                print("✅ PATCH mobile device \(id) succeeded with status \(http.statusCode).")
            }
        }
    }

    // MARK: - Classic API calls (fallback)

    func fetchBearerToken() async throws -> String {
        guard let username, let password else {
            throw JamfAPIError.invalidConfig
        }
        let url = baseURL.appendingPathComponent("/api/v1/auth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let loginString = "\(username):\(password)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw JamfAPIError.authFailed(status: nil, body: "Unable to encode credentials")
        }
        let base64Login = loginData.base64EncodedString()
        req.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }

        if let token = json["token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Missing 'token' key. Body: \(json)")
        }
    }

    private static func fetchClassicBearerToken(baseURL: URL, username: String?, password: String?) async throws -> String {
        guard let username, let password else {
            throw JamfAPIError.invalidConfig
        }
        let url = baseURL.appendingPathComponent("/api/v1/auth/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let loginString = "\(username):\(password)"
        guard let loginData = loginString.data(using: .utf8) else {
            throw JamfAPIError.authFailed(status: nil, body: "Unable to encode credentials")
        }
        let base64Login = loginData.base64EncodedString()
        req.setValue("Basic \(base64Login)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        JamfAPI.logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8)
            JamfAPI.logBodyIfError(bodyStr)
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Missing 'token' key. Body: \(json)")
        }
    }

    private mutating func validClassicToken() async throws -> String {
        if let token = classicToken, let expiry = classicExpiry, Date() < expiry.addingTimeInterval(-Self.expirySkew) {
            return token
        }

        if let task = classicFetchTask {
            let result = try await task.value
            setClassicCache(token: result.token, expiry: result.expiry)
            return result.token
        }

        let baseURL = self.baseURL
        theUsername: do {}
        let username = self.username
        let password = self.password

        let task = Task<(token: String, expiry: Date), Error> {
            let token = try await JamfAPI.fetchClassicBearerToken(baseURL: baseURL, username: username, password: password)
            let expiry = Date().addingTimeInterval(25 * 60)
            return (token, expiry)
        }
        classicFetchTask = task
        defer { classicFetchTask = nil }

        let result = try await task.value
        setClassicCache(token: result.token, expiry: result.expiry)
        return result.token
    }

    private mutating func setClassicCache(token: String, expiry: Date) {
        self.classicToken = token
        self.classicExpiry = expiry
    }

    mutating func updateLocation(deviceID: String, username: String?, realName: String?, email: String?, building: String?, department: String?, room: String?) async throws {
        let xml = buildLocationXML(username: username,
                                   realName: realName,
                                   email: email,
                                   building: building,
                                   department: department,
                                   room: room)
        guard let body = xml.data(using: .utf8) else { throw JamfAPIError.badResponse(status: nil, body: "Unable to encode XML") }

        let token = try await validClassicToken()
        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(deviceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")
        req.httpBody = body

        logRequest(req, redacting: ["Authorization"], bodyPreview: xml)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }
    }

    // MARK: - Diagnostics

    mutating func diagnoseModernAccess(deviceID: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/api/v2/mobile-devices/\(deviceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        logRequest(req)

        let (data, http) = try await authorizedModernRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
        }
        let json = String(data: data, encoding: .utf8) ?? ""
        return String(json.prefix(2048))
    }

    mutating func diagnoseClassicAccess(deviceID: String) async throws -> String {
        let token = try await validClassicToken()
        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(deviceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let preview = String(xml.prefix(2048))
        return preview
    }

    // MARK: - Classic list getters (return names)

    mutating func getBuildings() async throws -> [String] {
        if hasOAuth {
            let modern = try await getBuildingsModern()
            return modern.map { $0.name }
        }

        let token = try await validClassicToken()
        let url = baseURL.appendingPathComponent("/JSSResource/buildings")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }

        let xml = String(data: data, encoding: .utf8) ?? ""
        var names: [String] = []
        let pattern = "<name>(.*?)</name>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            regex.enumerateMatches(in: xml, options: [], range: range) { match, _, _ in
                if let match, match.numberOfRanges >= 2,
                   let r = Range(match.range(at: 1), in: xml) {
                    names.append(String(xml[r]))
                }
            }
        }
        return names
    }

    mutating func getDepartments() async throws -> [String] {
        if hasOAuth {
            let modern = try await getDepartmentsModern()
            return modern.map { $0.name }
        }

        let token = try await validClassicToken()
        let url = baseURL.appendingPathComponent("/JSSResource/departments")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }

        let xml = String(data: data, encoding: .utf8) ?? ""
        var names: [String] = []
        let pattern = "<name>(.*?)</name>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            regex.enumerateMatches(in: xml, options: [], range: range) { match, _, _ in
                if let match, match.numberOfRanges >= 2,
                   let r = Range(match.range(at: 1), in: xml) {
                    names.append(String(xml[r]))
                }
            }
        }
        return names
    }

    struct ValidationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    mutating func validateBuilding(_ building: String) async -> Result<Void, ValidationError> {
        do {
            let names = try await getBuildings()
            if names.contains(where: { $0 == building }) {
                return .success(())
            } else {
                let list = names.joined(separator: ", ")
                return .failure(ValidationError(message: "Building '\(building)' is not defined in Jamf. Available: \(list)"))
            }
        } catch let err as JamfAPIError {
            return .failure(ValidationError(message: "Unable to fetch buildings: \(err.description)"))
        } catch {
            return .failure(ValidationError(message: "Unable to fetch buildings: \(error.localizedDescription)"))
        }
    }

    mutating func validateDepartment(_ department: String) async -> Result<Void, ValidationError> {
        do {
            let names = try await getDepartments()
            if names.contains(where: { $0 == department }) {
                return .success(())
            } else {
                let list = names.joined(separator: ", ")
                return .failure(ValidationError(message: "Department '\(department)' is not defined in Jamf. Available: \(list)"))
            }
        } catch let err as JamfAPIError {
            return .failure(ValidationError(message: "Unable to fetch departments: \(err.description)"))
        } catch {
            return .failure(ValidationError(message: "Unable to fetch departments: \(error.localizedDescription)"))
        }
    }

    // MARK: - Prefill helpers

    struct LocationSnapshot {
        var username: String?
        var realName: String?
        var email: String?
        var room: String?

        // Modern IDs when available
        var buildingId: String?
        var departmentId: String?

        // Classic names when available
        var buildingName: String?
        var departmentName: String?
    }

    mutating func fetchCurrentLocationModern(id: String) async throws -> LocationSnapshot {
        let device = try await getMobileDeviceModern(id: id)
        let loc = device.location
        return LocationSnapshot(
            username: loc?.username,
            realName: loc?.realName,
            email: loc?.emailAddress,
            room: loc?.room,
            buildingId: loc?.buildingId,
            departmentId: loc?.departmentId,
            buildingName: nil,
            departmentName: nil
        )
    }

    mutating func fetchCurrentLocationClassic(id: String) async throws -> LocationSnapshot {
        let token = try await validClassicToken()
        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: (resp as? HTTPURLResponse)?.statusCode, body: bodyStr)
        }
        let xml = String(data: data, encoding: .utf8) ?? ""

        func firstMatch(_ tag: String) -> String? {
            let pattern = "<\(tag)>(.*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            if let m = regex.firstMatch(in: xml, options: [], range: range),
               m.numberOfRanges >= 2,
               let r = Range(m.range(at: 1), in: xml) {
                let val = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                return val.isEmpty ? nil : val
            }
            return nil
        }

        return LocationSnapshot(
            username: firstMatch("username"),
            realName: firstMatch("real_name"),
            email: firstMatch("email"),
            room: firstMatch("room"),
            buildingId: nil,
            departmentId: nil,
            buildingName: firstMatch("building"),
            departmentName: firstMatch("department")
        )
    }

    // MARK: - Helpers

    private func buildLocationXML(username: String?, realName: String?, email: String?, building: String?, department: String?, room: String?) -> String {
        func tag(_ name: String, _ value: String?) -> String { value.map { "<\(name)>\($0.xmlEscaped)</\(name)>" } ?? "" }
        return """
        <mobile_device>
          <location>
            \(tag("username", username))
            \(tag("real_name", realName))
            \(tag("email", email))
            \(tag("building", building))
            \(tag("department", department))
            \(tag("room", room))
          </location>
        </mobile_device>
        """
    }

    private static func shouldLog() -> Bool { verboseLogging || _isDebugAssertConfiguration() }

    private func logRequest(_ req: URLRequest, redacting headersToRedact: [String] = [], bodyPreview: String? = nil) {
        guard Self.shouldLog() else { return }
        var headerDump: [String: String] = [:]
        (req.allHTTPHeaderFields ?? [:]).forEach { k, v in
            if headersToRedact.contains(k) {
                headerDump[k] = "REDACTED"
            } else {
                headerDump[k] = v
            }
        }
        print("➡️ \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "")")
        print("Headers: \(headerDump)")
        if let bodyPreview, !bodyPreview.isEmpty {
            print("Body (preview):\n\(bodyPreview)")
        }
    }

    private func logBodyIfError(_ body: String?) {
        guard Self.shouldLog() else { return }
        if let body, !body.isEmpty {
            print("Body:\n\(body)")
        }
    }

    private static func logRequest(_ req: URLRequest, redacting headersToRedact: [String] = [], bodyPreview: String? = nil) {
        guard shouldLog() else { return }
        var headerDump: [String: String] = [:]
        (req.allHTTPHeaderFields ?? [:]).forEach { k, v in
            if headersToRedact.contains(k) {
                headerDump[k] = "REDACTED"
            } else {
                headerDump[k] = v
            }
        }
        print("➡️ \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "")")
        print("Headers: \(headerDump)")
        if let bodyPreview, !bodyPreview.isEmpty {
            print("Body (preview):\n\(bodyPreview)")
        }
    }

    private static func httpMeta(_ resp: URLResponse) -> (Int?, [String: String]) {
        if let http = resp as? HTTPURLResponse {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                let (k, v) = pair
                acc[String(describing: k)] = String(describing: v)
            }
            return (http.statusCode, headers)
        }
        return (nil, [:])
    }

    static func describe(status: Int?, body: String?) -> String {
        var parts: [String] = []
        if let status { parts.append(" status=\(status)") }
        if let body, !body.isEmpty { parts.append(" body=\(body)") }
        return parts.isEmpty ? "" : " (\(parts.joined()))"
    }

    // New: static counterpart so static call sites compile
    private static func logBodyIfError(_ body: String?) {
        guard shouldLog() else { return }
        if let body, !body.isEmpty {
            print("Body:\n\(body)")
        }
    }
}

private extension String {
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
