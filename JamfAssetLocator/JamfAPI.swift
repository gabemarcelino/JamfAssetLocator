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

    // Logging control: nil = default to build configuration; true/false = forced override
    private static var loggingOverride: Bool? = nil

    // Unique build/runtime signature for diagnostics
    private static let buildSignature: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let ts = formatter.string(from: Date())
        return "JamfAPI.swift signature: \(ts)"
    }()

    // MARK: - In-memory token caches (shared across all instances; no Keychain)
    private static let expirySkew: TimeInterval = 60

    // OAuth (/api/oauth/token) cache (static/shared)
    private static var oauthToken: String?
    private static var oauthExpiry: Date?
    private static var oauthFetchTask: Task<(token: String, expiry: Date), Error>?

    // Classic (/api/v1/auth/token) cache (static/shared)
    private static var classicToken: String?
    private static var classicExpiry: Date?
    private static var classicFetchTask: Task<(token: String, expiry: Date), Error>?

    init?(config: ManagedConfig) {
        // Allow managed config to control logging (quiet by default unless explicitly enabled)
        Self.loggingOverride = config.logVerboseOverride

        if Self.shouldLog() {
            print(Self.buildSignature)
        }

        guard let urlStr = config.jamfURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlStr.isEmpty,
              let url = URL(string: urlStr) else {
            if Self.shouldLog() {
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

        if Self.shouldLogDetailed() {
            let hasOAuthID = (self.clientID != nil)
            let hasOAuthSecret = (self.clientSecret != nil)
            let hasUser = (self.username != nil)
            let hasPass = (self.password != nil)
            print("JamfAPI.init: URL ok. OAuth(clientID:\(hasOAuthID), clientSecret:\(hasOAuthSecret)) Classic(username:\(hasUser), password:\(hasPass))")
        }

        let oauthComplete = (self.clientID != nil && self.clientSecret != nil)
        let classicComplete = (self.username != nil && self.password != nil)

        if !oauthComplete && !classicComplete {
            if Self.shouldLog() {
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
        if let token = Self.oauthToken, let expiry = Self.oauthExpiry, Date() < expiry.addingTimeInterval(-Self.expirySkew) {
            return token
        }

        if let task = Self.oauthFetchTask {
            let result = try await task.value
            Self.setOAuthCache(token: result.token, expiry: result.expiry)
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
        Self.oauthFetchTask = task
        defer { Self.oauthFetchTask = nil }

        let result = try await task.value
        Self.setOAuthCache(token: result.token, expiry: result.expiry)
        return result.token
    }

    private static func setOAuthCache(token: String, expiry: Date) {
        Self.oauthToken = token
        Self.oauthExpiry = expiry
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

        // Do NOT log body; contains client_secret
        logRequest(req, redacting: ["Authorization"])

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

        // Do NOT log body; contains client_secret
        JamfAPI.logRequest(req, redacting: ["Authorization"])

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

        // Avoid logging body for token endpoints; always redact Authorization
        logRequest(req, redacting: ["Authorization"])

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

        // Avoid logging body for token endpoints; always redact Authorization
        JamfAPI.logRequest(req, redacting: ["Authorization"])

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
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Non‑JSON or unexpected body: \(bodyStr ?? "nil")")
        }
        if let token = json["access_token"] as? String {
            return token
        } else {
            throw JamfAPIError.authFailed(status: (resp as? HTTPURLResponse)?.statusCode, body: "Missing 'access_token' key. Body: \(json)")
        }
    }

    // MARK: - Modern API models

    struct PagedResponse<T: Decodable>: Decodable {
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

    // Decode-only; structure can vary across Jamf versions
    struct MobileDevice: Decodable {
        struct Location: Decodable {
            var username: String?
            var realName: String?
            var emailAddress: String?
            var position: String?
            var phoneNumber: String?
            var departmentId: String?
            var buildingId: String?
            var room: String?

            enum CodingKeys: String, CodingKey {
                case username
                case realName, real_name
                case emailAddress, email
                case position
                case phoneNumber, phone_number
                case departmentId, department_id
                case buildingId, building_id
                case room
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.username = try c.decodeIfPresent(String.self, forKey: .username)

                self.realName = try c.decodeIfPresent(String.self, forKey: .realName)
                    ?? c.decodeIfPresent(String.self, forKey: .real_name)

                self.emailAddress = try c.decodeIfPresent(String.self, forKey: .emailAddress)
                    ?? c.decodeIfPresent(String.self, forKey: .email)

                self.position = try c.decodeIfPresent(String.self, forKey: .position)

                self.phoneNumber = try c.decodeIfPresent(String.self, forKey: .phoneNumber)
                    ?? c.decodeIfPresent(String.self, forKey: .phone_number)

                if let s = try c.decodeIfPresent(String.self, forKey: .departmentId) {
                    self.departmentId = s
                } else if let s = try c.decodeIfPresent(String.self, forKey: .department_id) {
                    self.departmentId = s
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .departmentId) {
                    self.departmentId = String(i)
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .department_id) {
                    self.departmentId = String(i)
                }

                if let s = try c.decodeIfPresent(String.self, forKey: .buildingId) {
                    self.buildingId = s
                } else if let s = try c.decodeIfPresent(String.self, forKey: .building_id) {
                    self.buildingId = s
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .buildingId) {
                    self.buildingId = String(i)
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .building_id) {
                    self.buildingId = String(i)
                }

                self.room = try c.decodeIfPresent(String.self, forKey: .room)
            }

            init() {}
        }

        var name: String?
        var assetTag: String?
        var siteId: String?
        var timeZone: String?
        var location: Location?

        enum CodingKeys: String, CodingKey {
            case name
            case assetTag, asset_tag
            case siteId, site_id
            case timeZone, time_zone
            case location
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)

            // Robust: assetTag may be string or number, and key may be assetTag or asset_tag
            if let s = try c.decodeIfPresent(String.self, forKey: .assetTag) {
                self.assetTag = s
            } else if let i = try c.decodeIfPresent(Int.self, forKey: .assetTag) {
                self.assetTag = String(i)
            } else if let s2 = try c.decodeIfPresent(String.self, forKey: .asset_tag) {
                self.assetTag = s2
            } else if let i2 = try c.decodeIfPresent(Int.self, forKey: .asset_tag) {
                self.assetTag = String(i2)
            } else {
                self.assetTag = nil
            }

            if let s = try c.decodeIfPresent(String.self, forKey: .siteId) {
                self.siteId = s
            } else if let s = try c.decodeIfPresent(String.self, forKey: .site_id) {
                self.siteId = s
            } else if let i = try c.decodeIfPresent(Int.self, forKey: .siteId) {
                self.siteId = String(i)
            } else if let i = try c.decodeIfPresent(Int.self, forKey: .site_id) {
                self.siteId = String(i)
            }

            self.timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
                ?? c.decodeIfPresent(String.self, forKey: .time_zone)

            self.location = try c.decodeIfPresent(Location.self, forKey: .location)
        }
    }

    // v2 details endpoint (your tenant returns assetTag at top level)
    struct MobileDeviceDetails: Decodable {
        struct General: Decodable {
            var assetTag: String?
            enum CodingKeys: String, CodingKey {
                case assetTag, asset_tag
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let s = try c.decodeIfPresent(String.self, forKey: .assetTag) {
                    self.assetTag = s
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .assetTag) {
                    self.assetTag = String(i)
                } else if let s2 = try c.decodeIfPresent(String.self, forKey: .asset_tag) {
                    self.assetTag = s2
                } else if let i2 = try c.decodeIfPresent(Int.self, forKey: .asset_tag) {
                    self.assetTag = String(i2)
                } else {
                    self.assetTag = nil
                }
            }
        }

        var assetTag: String?          // NEW: top-level assetTag
        var general: General?
        var location: MobileDevice.Location?

        enum CodingKeys: String, CodingKey {
            case assetTag, asset_tag
            case general
            case location
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            // Top-level assetTag (string or int)
            if let s = try c.decodeIfPresent(String.self, forKey: .assetTag) {
                self.assetTag = s
            } else if let i = try c.decodeIfPresent(Int.self, forKey: .assetTag) {
                self.assetTag = String(i)
            } else if let s2 = try c.decodeIfPresent(String.self, forKey: .asset_tag) {
                self.assetTag = s2
            } else if let i2 = try c.decodeIfPresent(Int.self, forKey: .asset_tag) {
                self.assetTag = String(i2)
            } else {
                self.assetTag = nil
            }

            self.general = try c.decodeIfPresent(General.self, forKey: .general)
            self.location = try c.decodeIfPresent(MobileDevice.Location.self, forKey: .location)

            // Fallback: some tenants only provide under general
            if self.assetTag == nil {
                self.assetTag = self.general?.assetTag
            }
        }
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

        // NEW: Modern EA updates
        struct UpdatedExtensionAttribute: Codable {
            var name: String
            var type: String
            var value: [String]
            var extensionAttributeCollectionAllowed: Bool
        }
        var updatedExtensionAttributes: [UpdatedExtensionAttribute]?
    }

    // Fallback inventory model (richer payload; v1 inventory API)
    struct MobileDeviceInventory: Decodable {
        struct General: Decodable {
            var assetTag: String?
            enum CodingKeys: String, CodingKey {
                case assetTag, asset_tag
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let s = try c.decodeIfPresent(String.self, forKey: .assetTag) {
                    self.assetTag = s
                } else if let i = try c.decodeIfPresent(Int.self, forKey: .assetTag) {
                    self.assetTag = String(i)
                } else if let s2 = try c.decodeIfPresent(String.self, forKey: .asset_tag) {
                    self.assetTag = s2
                } else if let i2 = try c.decodeIfPresent(Int.self, forKey: .asset_tag) {
                    self.assetTag = String(i2)
                } else {
                    self.assetTag = nil
                }
            }
        }

        var assetTag: String?
        var location: MobileDevice.Location?

        enum CodingKeys: String, CodingKey {
            case general
            case location
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let general = try c.decodeIfPresent(General.self, forKey: .general) {
                self.assetTag = general.assetTag
            } else {
                self.assetTag = nil
            }
            self.location = try c.decodeIfPresent(MobileDevice.Location.self, forKey: .location)
        }
    }

    // MARK: - Modern API helpers

    private mutating func authorizedModernRequest(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = req
        let token = try await validOAuthToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logRequest(req, redacting: ["Authorization"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.badResponse(status: nil, body: "No HTTP response")
        }
        if (200...299).contains(http.statusCode) {
            if Self.shouldLog() {
                print("✅ \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "") -> \(http.statusCode)")
            }
            return (data, http)
        }

        if http.statusCode == 401 {
            // Token likely expired; fetch a fresh one, update cache, retry once.
            if Self.shouldLog() {
                print("🔁 401 Unauthorized, fetching a new OAuth token and retrying: \(req.url?.absoluteString ?? "")")
            }
            let newToken = try await fetchOAuthToken()
            JamfAPI.setOAuthCache(token: newToken, expiry: Date().addingTimeInterval(25 * 60))

            var retry = req
            retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            logRequest(retry, redacting: ["Authorization"])
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            guard let h2 = r2 as? HTTPURLResponse else {
                throw JamfAPIError.badResponse(status: nil, body: "No HTTP response (retry)")
            }
            if (200...299).contains(h2.statusCode) {
                if Self.shouldLog() {
                    print("✅ \(retry.httpMethod ?? "GET") \(retry.url?.absoluteString ?? "") -> \(h2.statusCode) (after token refresh)")
                }
            } else if h2.statusCode == 403, Self.shouldLog() {
                Self.logPrivilegeHint(method: retry.httpMethod, url: retry.url, status: h2.statusCode)
            }
            return (d2, h2)
        }

        if http.statusCode == 403, Self.shouldLog() {
            Self.logPrivilegeHint(method: req.httpMethod, url: req.url, status: http.statusCode)
        }
        return (data, http)
    }

    // Classic helper with 401 retry
    private mutating func authorizedClassicRequest(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = req
        let token = try await validClassicToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logRequest(req, redacting: ["Authorization"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw JamfAPIError.badResponse(status: nil, body: "No HTTP response")
        }
        if (200...299).contains(http.statusCode) {
            if Self.shouldLog() {
                print("✅ \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "") -> \(http.statusCode)")
            }
            return (data, http)
        }

        if http.statusCode == 401 {
            if Self.shouldLog() {
                print("🔁 401 Unauthorized (classic), fetching a new token and retrying: \(req.url?.absoluteString ?? "")")
            }
            // Get a fresh classic token and cache it
            let newToken = try await JamfAPI.fetchClassicBearerToken(baseURL: baseURL, username: username, password: password)
            JamfAPI.setClassicCache(token: newToken, expiry: Date().addingTimeInterval(25 * 60))

            var retry = req
            retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            logRequest(retry, redacting: ["Authorization"])
            let (d2, r2) = try await URLSession.shared.data(for: retry)
            guard let h2 = r2 as? HTTPURLResponse else {
                throw JamfAPIError.badResponse(status: nil, body: "No HTTP response (retry)")
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

    // v2 details endpoint (try before inventory)
    mutating func getMobileDeviceDetailsModern(id: String) async throws -> MobileDeviceDetails? {
        let url = baseURL.appendingPathComponent("/api/v2/mobile-devices/\(id)/detail")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        logRequest(req)

        let (data, http) = try await authorizedModernRequest(req)
        if (200...299).contains(http.statusCode) {
            do {
                let details = try JSONDecoder().decode(MobileDeviceDetails.self, from: data)
                if Self.shouldLog() {
                    print("📄 Details for device \(id) decoded")
                }
                return details
            } catch {
                if Self.shouldLog() {
                    let preview = String(data: data, encoding: .utf8) ?? ""
                    print("⚠️ Details decode failed, raw preview:\n\(String(preview.prefix(1024)))")
                }
                throw error
            }
        } else if http.statusCode == 404 {
            // Some Jamf versions don’t have this endpoint; treat as unavailable.
            if Self.shouldLog() {
                let body = String(data: data, encoding: .utf8)
                logBodyIfError(body)
                print("ℹ️ Details endpoint returned 404 for \(id); skipping.")
            }
            return nil
        } else {
            let body = String(data: data, encoding: .utf8)
            logBodyIfError(body)
            throw JamfAPIError.badResponse(status: http.statusCode, body: body)
        }
    }

    // Fallback: richer inventory endpoint (often includes location/assetTag)
    mutating func getMobileDeviceInventoryModern(id: String) async throws -> MobileDeviceInventory? {
        // First attempt: filter=id=={id}
        func requestInventory(with queryItems: [URLQueryItem], label: String) async throws -> (MobileDeviceInventory?, HTTPURLResponse) {
            var comps = URLComponents(url: baseURL.appendingPathComponent("/api/v1/mobile-devices-inventory"), resolvingAgainstBaseURL: false)!
            comps.queryItems = queryItems
            guard let url = comps.url else { throw JamfAPIError.invalidConfig }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            logRequest(req)

            let (data, http) = try await authorizedModernRequest(req)
            if (200...299).contains(http.statusCode) {
                do {
                    let pageResp = try JSONDecoder().decode(PagedResponse<MobileDeviceInventory>.self, from: data)
                    if Self.shouldLog() {
                        print("📦 Inventory(\(label)) returned \(pageResp.totalCount) result(s) for id \(id)")
                    }
                    return (pageResp.results.first, http)
                } catch {
                    if Self.shouldLog() {
                        let preview = String(data: data, encoding: .utf8) ?? ""
                        print("⚠️ Inventory(\(label)) decode failed, raw preview:\n\(String(preview.prefix(1024)))")
                    }
                    throw error
                }
            } else {
                let bodyStr = String(data: data, encoding: .utf8)
                logBodyIfError(bodyStr)
                return (nil, http)
            }
        }

        // Try filter form
        let (firstResult, firstHTTP) = try await requestInventory(
            with: [
                URLQueryItem(name: "filter", value: "id==\(id)"),
                URLQueryItem(name: "page-size", value: "1")
            ],
            label: "filter"
        )

        if (200...299).contains(firstHTTP.statusCode) {
            return firstResult
        }

        // If 404 (not found/unsupported), try alternate ids= form (some Jamf versions prefer this)
        if firstHTTP.statusCode == 404 {
            if Self.shouldLog() {
                print("ℹ️ Inventory filter form returned 404; trying ids= variant for id \(id)")
            }
            let (secondResult, secondHTTP) = try await requestInventory(
                with: [
                    URLQueryItem(name: "ids", value: id),
                    URLQueryItem(name: "section", value: "GENERAL"),
                    URLQueryItem(name: "page-size", value: "1")
                ],
                label: "ids"
            )
            if (200...299).contains(secondHTTP.statusCode) {
                return secondResult
            }
            if secondHTTP.statusCode == 404 {
                // Graceful: treat as "no results"
                if Self.shouldLog() {
                    print("ℹ️ Inventory ids form also returned 404; treating as no results for id \(id)")
                }
                return nil
            }
            // Other error codes: bubble up
            throw JamfAPIError.badResponse(status: secondHTTP.statusCode, body: nil)
        }

        // Other error codes from the first attempt: bubble up
        throw JamfAPIError.badResponse(status: firstHTTP.statusCode, body: nil)
    }

    mutating func patchMobileDeviceModern(id: String, payload: MobileDevicePatch) async throws {
        let url = baseURL.appendingPathComponent("/api/v2/mobile-devices/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(payload)
        req.httpBody = body

        // Only show minimal request line by default; body preview logged only in verbose mode
        logRequest(req, bodyPreview: String(data: body, encoding: .utf8))

        let (data, http) = try await authorizedModernRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
        }
        if Self.shouldLog() {
            let respPreview = String(data: data, encoding: .utf8)
            if let respPreview, !respPreview.isEmpty, Self.shouldLogDetailed() {
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
        if let token = Self.classicToken, let expiry = Self.classicExpiry, Date() < expiry.addingTimeInterval(-Self.expirySkew) {
            return token
        }

        if let task = Self.classicFetchTask {
            let result = try await task.value
            Self.setClassicCache(token: result.token, expiry: result.expiry)
            return result.token
        }

        let baseURL = self.baseURL
        let username = self.username
        let password = self.password

        let task = Task<(token: String, expiry: Date), Error> {
            let token = try await JamfAPI.fetchClassicBearerToken(baseURL: baseURL, username: username, password: password)
            let expiry = Date().addingTimeInterval(25 * 60)
            return (token, expiry)
        }
        Self.classicFetchTask = task
        defer { Self.classicFetchTask = nil }

        let result = try await task.value
        Self.setClassicCache(token: result.token, expiry: result.expiry)
        return result.token
    }

    private static func setClassicCache(token: String, expiry: Date) {
        Self.classicToken = token
        Self.classicExpiry = expiry
    }

    mutating func updateLocation(
        deviceID: String,
        username: String?,
        realName: String?,
        email: String?,
        building: String?,
        department: String?,
        room: String?,
        assetTag: String?
    ) async throws {
        let xml = buildMobileDeviceUpdateXML(
            assetTag: assetTag,
            username: username,
            realName: realName,
            email: email,
            building: building,
            department: department,
            room: room
        )
        guard let body = xml.data(using: .utf8) else { throw JamfAPIError.badResponse(status: nil, body: "Unable to encode XML") }

        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(deviceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.setValue("application/xml", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let (data, http) = try await authorizedClassicRequest(req)

        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
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
        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(deviceID)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, http) = try await authorizedClassicRequest(req)

        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
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

        let url = baseURL.appendingPathComponent("/JSSResource/buildings")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, http) = try await authorizedClassicRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
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

        let url = baseURL.appendingPathComponent("/JSSResource/departments")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, http) = try await authorizedClassicRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
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
        var assetTag: String?

        // Modern IDs when available
        var buildingId: String?
        var departmentId: String?

        // Classic names when available
        var buildingName: String?
        var departmentName: String?
    }

    mutating func fetchCurrentLocationModern(id: String) async throws -> LocationSnapshot {
        let device = try await getMobileDeviceModern(id: id)
        if Self.shouldLogDetailed() {
            print("Decoded MobileDevice for \(id): \(device)")
        }
        var loc = device.location
        var tag = device.assetTag

        // Try v2 details (often includes both)
        if (loc == nil) || (tag == nil) {
            do {
                if let details = try await getMobileDeviceDetailsModern(id: id) {
                    if tag == nil { tag = details.assetTag ?? details.general?.assetTag }
                    if loc == nil { loc = details.location }
                }
            } catch {
                if Self.shouldLog() {
                    print("⚠️ Details request failed for id \(id): \(error.localizedDescription)")
                }
            }
        }

        // Fallback to inventory if still missing
        if (loc == nil) || (tag == nil) {
            if Self.shouldLog() {
                print("ℹ️ Still missing location/assetTag; attempting inventory fallback for id \(id)")
            }
            do {
                if let inv = try await getMobileDeviceInventoryModern(id: id) {
                    if tag == nil { tag = inv.assetTag }
                    if loc == nil { loc = inv.location }
                } else if Self.shouldLog() {
                    print("⚠️ Inventory returned no results for id \(id)")
                }
            } catch {
                if Self.shouldLog() {
                    print("⚠️ Inventory request failed for id \(id): \(error.localizedDescription)")
                }
                // Continue without failing prefill
            }
        }

        return LocationSnapshot(
            username: loc?.username,
            realName: loc?.realName,
            email: loc?.emailAddress,
            room: loc?.room,
            assetTag: tag,
            buildingId: loc?.buildingId,
            departmentId: loc?.departmentId,
            buildingName: nil,
            departmentName: nil
        )
    }

    mutating func fetchCurrentLocationClassic(id: String) async throws -> LocationSnapshot {
        let url = baseURL.appendingPathComponent("/JSSResource/mobiledevices/id/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/xml", forHTTPHeaderField: "Accept")

        logRequest(req, redacting: ["Authorization"])

        let (data, http) = try await authorizedClassicRequest(req)
        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            logBodyIfError(bodyStr)
            throw JamfAPIError.badResponse(status: http.statusCode, body: bodyStr)
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
            assetTag: firstMatch("asset_tag"),
            buildingId: nil,
            departmentId: nil,
            buildingName: firstMatch("building"),
            departmentName: firstMatch("department")
        )
    }

    // MARK: - Helpers

    private func buildMobileDeviceUpdateXML(
        assetTag: String?,
        username: String?,
        realName: String?,
        email: String?,
        building: String?,
        department: String?,
        room: String?
    ) -> String {
        func tag(_ name: String, _ value: String?) -> String { value.map { "<\(name)>\($0.xmlEscaped)</\(name)>" } ?? "" }

        let generalSection: String = {
            guard let assetTag else { return "" }
            return """
              <general>
                \(tag("asset_tag", assetTag))
              </general>
            """
        }()

        return """
        <mobile_device>
        \(generalSection)
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

    private static func shouldLog() -> Bool {
        // If an override is set (true/false), use it; otherwise default to quiet unless explicitly enabled in Debug.
        if let override = loggingOverride { return override }
        return false
    }

    private static func shouldLogDetailed() -> Bool {
        // Only when explicitly enabled
        return loggingOverride == true
    }

    private func logRequest(_ req: URLRequest, redacting headersToRedact: [String] = [], bodyPreview: String? = nil) {
        guard Self.shouldLog() else { return }
        let method = req.httpMethod ?? "GET"
        let urlStr = req.url?.absoluteString ?? ""
        print("➡️ \(method) \(urlStr)")
        if Self.shouldLogDetailed() {
            let headerDump = JamfAPI.redactedHeaders(req.allHTTPHeaderFields ?? [:], extra: headersToRedact)
            print("Headers: \(headerDump)")
            if let bodyPreview, !bodyPreview.isEmpty {
                print("Body (preview):\n\(bodyPreview)")
            }
        }
    }

    private func logBodyIfError(_ body: String?) {
        guard Self.shouldLog() else { return }
        if let body, !body.isEmpty {
            let preview = String(body.prefix(2048))
            let suffix = body.count > 2048 ? "\n…(truncated)" : ""
            print("Body:\n\(preview)\(suffix)")
        }
    }

    private static func logRequest(_ req: URLRequest, redacting headersToRedact: [String] = [], bodyPreview: String? = nil) {
        guard shouldLog() else { return }
        let method = req.httpMethod ?? "GET"
        let urlStr = req.url?.absoluteString ?? ""
        print("➡️ \(method) \(urlStr)")
        if shouldLogDetailed() {
            let headerDump = redactedHeaders(req.allHTTPHeaderFields ?? [:], extra: headersToRedact)
            print("Headers: \(headerDump)")
            if let bodyPreview, !bodyPreview.isEmpty {
                print("Body (preview):\n\(bodyPreview)")
            }
        }
    }

    private static func redactedHeaders(_ headers: [String: String], extra: [String]) -> [String: String] {
        let sensitive = Set(extra.map { $0.lowercased() })
        return headers.reduce(into: [String: String]()) { acc, kv in
            let (k, v) = kv
            let lower = k.lowercased()
            let shouldRedact =
                sensitive.contains(lower) ||
                lower.contains("authorization") ||
                lower.contains("token") ||
                lower.contains("secret") ||
                lower.contains("password") ||
                lower.contains("cookie")
            acc[k] = shouldRedact ? "REDACTED" : v
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
            let preview = String(body.prefix(2048))
            let suffix = body.count > 2048 ? "\n…(truncated)" : ""
            print("Body:\n\(preview)\(suffix)")
        }
    }

    private static func logPrivilegeHint(method: String?, url: URL?, status: Int) {
        guard let path = url?.path else {
            print("🚫 \(method ?? "REQUEST") -> \(status) Forbidden")
            return
        }
        var hint = ""
        switch true {
        case path.hasPrefix("/api/v2/mobile-devices") || path.hasPrefix("/api/v1/mobile-devices-inventory"):
            hint = "Missing privilege? Grant 'Read Mobile Devices' (and 'Update Mobile Devices' for PATCH)."
        case path.hasPrefix("/api/v1/buildings"):
            hint = "Missing privilege? Grant 'Read Buildings'."
        case path.hasPrefix("/api/v1/departments"):
            hint = "Missing privilege? Grant 'Read Departments'."
        default:
            hint = "Check the API role privileges for this endpoint."
        }
        print("🚫 \(method ?? "REQUEST") \(path) -> \(status) Forbidden. \(hint)")
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

