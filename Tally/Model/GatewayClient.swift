import CryptoKit
import Darwin
import Foundation

enum GatewayVersion: String, CaseIterable, Identifiable {
    case v1_106_2 = "1.106.2"
    case v1_49_6 = "1.49.6"
    case connector = "connector"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connector: "Connector"
        default: "LiteLLM \(rawValue)"
        }
    }

    /// Spend logs are mounted on the gateway origin. A client base such as `/v1` is not part of the path.
    /// The connector path is the public contract, not a route on the private gateway.
    var spendPath: String {
        switch self {
        case .v1_106_2: "/spend/logs/v2"
        case .v1_49_6: "/spend/logs"
        case .connector: "/tally/v1/requests"
        }
    }
}

enum TrackingAuth {
    struct Credential: Equatable {
        var accessToken: String
        var expiresIn: TimeInterval
        var refreshToken: String?
        var scope: String
    }

    static let redirectURI = "tally://callback"

    static func makeChallenge(verifier: String = randomVerifier()) -> (verifier: String, challenge: String) {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }

    /// Query is only the code exchange. There is no parameter for a master key or a tracking key.
    static func authorizeURL(endpoint: String, clientID: String, state: String, challenge: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else { return nil }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "spend.read"),
        ]
        return components.url
    }

    static func codeForm(clientID: String, code: String, verifier: String) -> String {
        form([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
    }

    static func refreshForm(clientID: String, refreshToken: String) -> String {
        form([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
    }

    static func revokeForm(token: String) -> String {
        form([
            ("token", token),
            ("token_type_hint", "refresh_token"),
        ])
    }

    static func parse(_ data: Data) -> Result<Credential, GatewayClient.Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(rejected)
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            return .failure(rejected)
        }
        let expiresIn: TimeInterval
        if let number = object["expires_in"] as? NSNumber {
            expiresIn = number.doubleValue
        } else if let text = object["expires_in"] as? String, let value = TimeInterval(text) {
            expiresIn = value
        } else {
            return .failure(rejected)
        }
        guard expiresIn > 0 else { return .failure(rejected) }
        let refresh = object["refresh_token"] as? String
        let rawScope = (object["scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scope = (rawScope == "this user" || rawScope == "team") ? rawScope : "this key"
        return .success(Credential(
            accessToken: access,
            expiresIn: expiresIn,
            refreshToken: refresh.flatMap { $0.isEmpty ? nil : $0 },
            scope: scope
        ))
    }

    /// A pasted key has no expiry. An issued key is expired at the stored instant.
    static func isExpired(expiry: TimeInterval, now: Date) -> Bool {
        expiry > 0 && now.timeIntervalSince1970 >= expiry
    }

    static func randomState() -> String {
        randomToken(count: 32)
    }

    static let rejected = GatewayClient.Failure(
        message: "The operator did not issue a tracking key.",
        action: "Sign in again."
    )

    private static func randomVerifier() -> String {
        randomToken(count: 43)
    }

    private static func randomToken(count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in
            alphabet[Int(UInt8.random(in: 0...255, using: &generator)) % alphabet.count]
        })
    }

    private static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// Percent-encode every byte that is not an unreserved character.
    private static func encode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            if isUnreserved(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }
}

enum GatewayClient {
    struct Failure: Error, Equatable {
        var message: String
        var action: String

        static func http(_ status: Int) -> Failure {
            switch status {
            case 401:
                return Failure(
                    message: "The gateway rejected this API key.",
                    action: "Paste the virtual key again."
                )
            case 403:
                return Failure(
                    message: "This key cannot read spend logs.",
                    action: "Allow this key to read spend logs."
                )
            case 404:
                return Failure(
                    message: "The spend route was not found. The proxy may be hiding it.",
                    action: "Expose the spend-log route. A proxy may be hiding it."
                )
            default:
                return Failure(
                    message: "The gateway returned HTTP \(status).",
                    action: "Confirm the spend URL and that this key can read spend logs."
                )
            }
        }

        static let unreachable = Failure(
            message: "Couldn’t reach the gateway.",
            action: "Confirm the spend URL is reachable."
        )
        static let loginPage = Failure(
            message: "The gateway returned a login page, not spend data.",
            action: "Point the spend URL at the spend-log route, not the login page."
        )
        static let dailyTotals = Failure(
            message: "This URL returned daily totals, not requests.",
            action: "Point the spend URL at request rows. Daily totals cannot be listed as requests."
        )
        static let unsupported = Failure(
            message: "This response is not a supported spend log.",
            action: "Return request rows that include a request id."
        )
        /// The key authenticated, and the spend log is reserved for a proxy admin.
        static let memberRoute = Failure(
            message: "This key is a member and its spend route did not respond.",
            action: "Confirm the gateway serves member spend for this key."
        )
        static let invalidURL = Failure(
            message: "Enter an https spend URL.",
            action: "Enter an https spend URL."
        )
        static let sameDestination = Failure(
            message: "The spend URL and the key page must be different.",
            action: "Use a key page URL that is not the spend URL."
        )
        static let unapproved = Failure(
            message: "Confirm this spend host before the saved key is sent.",
            action: "Review the spend host, then confirm that the saved key may be sent there."
        )
        static let privateAddress = Failure(
            message: "This host is a private or metadata address. The key was not sent.",
            action: "Use a public https spend URL. A private gateway needs a connector."
        )
        static let unresolved = Failure(
            message: "Couldn’t resolve this host. The key was not sent.",
            action: "Check the address and try again."
        )
        static let redirected = Failure(
            message: "The gateway redirected away from the approved host. The key was not sent there.",
            action: "Point the spend URL at the host that serves spend logs."
        )
        static let profileRefused = Failure(
            message: "The profile host refused the download. No API key was sent.",
            action: "Publish the profile so it can be downloaded without a key."
        )
        static let profileMissing = Failure(
            message: "The hosted profile was not found.",
            action: "Confirm the profile address and that the file is published."
        )
        static let profileRedirected = Failure(
            message: "The profile host redirected to another host. The file was not downloaded.",
            action: "Host the profile at the address in the setup link."
        )
        static let profileUnreachable = Failure(
            message: "Couldn’t reach the profile host.",
            action: "Confirm the hosted profile address is reachable."
        )
        static let profilePrivate = Failure(
            message: "This profile address is a private or metadata host. It was not downloaded.",
            action: "Host the profile at a public https address."
        )
        static let profileTooLarge = Failure(
            message: "The hosted profile is larger than 64 KB.",
            action: "Export the profile from Tally and host that file."
        )

        static func profileHTTP(_ status: Int) -> Failure {
            Failure(
                message: "The profile host returned HTTP \(status).",
                action: "Confirm the hosted profile address."
            )
        }
    }

    /// Admin keys read spend logs. Member keys read their own spend totals.
    enum GatewayRole: Equatable {
        case admin
        case member
    }

    struct MemberSpend: Equatable {
        var today: Double
        var month: Double
        var todayModels: [ModelTotal]
        var monthModels: [ModelTotal]
    }

    struct Read {
        var requests: [UsageRequest]
        var truncated: Bool
        var role: GatewayRole = .admin
        var member: MemberSpend? = nil
    }

    static let rowCap = 2_000
    static let truncationNotice = "Showing the first 2,000 requests in this window."
    static let memberNotice = "Member key. Totals come from your spend. Request history needs an admin key."

    static func presetSpendURL(_ gatewayURL: String, version: GatewayVersion) -> String {
        let trimmed = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else { return "" }
        components.user = nil
        components.password = nil
        components.path = version.spendPath
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    /// Same scheme, host, port, and path. The query is ignored because the adapter replaces it.
    static func sameDestination(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = URL(string: lhs.trimmingCharacters(in: .whitespacesAndNewlines)),
              let right = URL(string: rhs.trimmingCharacters(in: .whitespacesAndNewlines)),
              left.host?.isEmpty == false,
              right.host?.isEmpty == false else { return false }
        return identity(left) == identity(right)
    }

    static func fetch(
        spendURL: String,
        version: GatewayVersion,
        apiKey: String,
        keyPageURL: String = "",
        now: Date = Date()
    ) async -> Result<Read, Failure> {
        let trimmed = spendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            return .failure(.invalidURL)
        }
        if sameDestination(trimmed, keyPageURL) {
            return .failure(.sameDestination)
        }
        if let failure = screen(spendURL: trimmed, keyPageURL: keyPageURL) {
            return .failure(failure)
        }
        let approved = hostKey(of: trimmed)
        if version == .connector {
            return await fetchContract(
                components: components,
                apiKey: apiKey,
                approvedHostKey: approved,
                keyPageURL: keyPageURL,
                now: now
            )
        }

        let start = windowStart(now)
        let paged = version == .v1_106_2
        var page = 1
        var collected: [[String: Any]] = []
        var truncated = false
        var done = false

        while page <= 10 && !done {
            if paged {
                components.queryItems = [
                    URLQueryItem(name: "start_date", value: timestamp(start)),
                    URLQueryItem(name: "end_date", value: timestamp(now)),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page_size", value: "200"),
                ]
            } else {
                components.query = nil
                components.queryItems = nil
            }
            guard let url = components.url else {
                return .failure(.invalidURL)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            switch await send(request, approvedHostKey: approved, keyPageURL: keyPageURL) {
            case .data(let data):
                switch classify(data) {
                case .loginPage:
                    return .failure(.loginPage)
                case .dailyTotals:
                    return .failure(.dailyTotals)
                case .unsupported:
                    return .failure(.unsupported)
                case .rows(let rows):
                    collected = rows
                    done = true
                case .page(let rows, let totalPages):
                    collected.append(contentsOf: rows)
                    if !paged || rows.isEmpty || page >= totalPages {
                        done = true
                    } else if page == 10 && totalPages > 10 {
                        truncated = true
                        done = true
                    } else {
                        page += 1
                    }
                }
            case .status(let code, let body):
                if collected.isEmpty, roleRefusal(body) {
                    return await fetchMember(spendURL: trimmed, apiKey: apiKey, keyPageURL: keyPageURL)
                }
                return .failure(.http(code))
            case .redirect:
                return .failure(.redirected)
            case .unreachable:
                return .failure(.unreachable)
            }
        }

        var read = finish(collected, now: now, version: version)
        if truncated { read.truncated = true }
        return .success(read)
    }

    #if DEBUG
    static func selfCheck() {
        let v2 = Data(
            """
            {"data":[
              {"request_id":"a","startTime":"2026-10-24 12:00:00","model":"anthropic/claude-sonnet","prompt_tokens":10,"completion_tokens":4,"spend":0.5,"status":"success","session_id":"draft","request_tags":["User-Agent: test"],"messages":[{"role":"user","content":"secret"}]},
              {"request_id":"b","start_time":"2026-10-24 13:00:00","model":"gpt-4o","prompt_tokens":2,"completion_tokens":1,"spend":0.25,"status":"failure","session_id":"","request_tags":["User-Agent: x","review"],"response":"hidden"}
            ],"total_pages":1}
            """.utf8
        )
        guard case .page(let pageRows, let pages) = classify(v2) else {
            assertionFailure("v2 page")
            return
        }
        assert(pages == 1)
        let parsed = parse(pageRows)
        assert(parsed.count == 2)
        assert(parsed[0].requestID == "a")
        assert(parsed[0].model.id == "anthropic/claude-sonnet")
        assert(parsed[0].input == 10)
        assert(parsed[0].output == 4)
        assert(parsed[0].cost == 0.5)
        assert(parsed[0].status == 200)
        assert(parsed[0].conversation == "draft")
        assert(parsed[1].model.id == "gpt-4o")
        assert(parsed[1].cost == 0.25)
        assert(parsed[1].status == 500)
        assert(parsed[1].conversation == "review")
        assert(parsed.allSatisfy { $0.conversation != "secret" && $0.conversation != "hidden" })

        let old = Data(
            """
            [
              {"request_id":"a","startTime":"2026-10-24 12:00:00","model":"gpt-4o","prompt_tokens":3,"completion_tokens":1,"spend":0.1,"status":"success"},
              {"request_id":"a","startTime":"2026-10-24 12:00:01","model":"gpt-4o","prompt_tokens":9,"completion_tokens":1,"spend":9,"status":"success"}
            ]
            """.utf8
        )
        guard case .rows(let oldRows) = classify(old) else {
            assertionFailure("1.49.6 rows")
            return
        }
        let deduped = deduped(parse(oldRows))
        assert(deduped.count == 1)
        assert(deduped[0].requestID == "a")
        assert(deduped[0].cost == 0.1)

        let totals = Data(
            """
            [{"startTime":"2026-10-24","spend":12.5,"users":{"a":1},"models":{"gpt-4o":{"spend":12.5}}}]
            """.utf8
        )
        guard case .dailyTotals = classify(totals) else {
            assertionFailure("daily totals")
            return
        }
        guard case .loginPage = classify(Data("<html><body>Sign in</body></html>".utf8)) else {
            assertionFailure("login page")
            return
        }

        assert(presetSpendURL("https://llm.example.com/v1", version: .v1_106_2) == "https://llm.example.com/spend/logs/v2")
        assert(presetSpendURL("https://llm.example.com/", version: .v1_49_6) == "https://llm.example.com/spend/logs")
        assert(sameDestination("https://llm.example.com/spend/logs", "https://llm.example.com/spend/logs?page=1"))
        assert(!sameDestination("https://llm.example.com/spend/logs", "https://llm.example.com/key"))

        let now = date("2026-10-24 18:00:00")!
        let capped = finish([
            ["request_id": "old", "startTime": "2026-09-01 00:00:00", "model": "gpt-4o", "spend": 4, "prompt_tokens": 1, "completion_tokens": 1],
            ["request_id": "new", "startTime": "2026-10-24 12:00:00", "model": "gpt-4o", "spend": 1, "prompt_tokens": 2, "completion_tokens": 3],
        ], now: now, version: .v1_49_6)
        assert(capped.requests.count == 1)
        assert(capped.requests[0].requestID == "new")
        assert(!capped.truncated)

        assert(Failure.http(401).message == "The gateway rejected this API key.")
        assert(Failure.http(403).message == "This key cannot read spend logs.")
        let adminOnly = Data(
            #"{"error":{"message":"Authentication Error, Only proxy admin can be used. Route=/spend/logs/v2. Your role=unknown.","code":"401"}}"#.utf8
        )
        let missingKey = Data(
            #"{"error":{"message":"Authentication Error, No api key passed in.","code":"401"}}"#.utf8
        )
        assert(roleRefusal(adminOnly))
        assert(!roleRefusal(missingKey))
        let memberBody = Data(
            #"{"daily_spend":1.5,"monthly_spend":9.25,"model_spend_today":{"gpt-4o":1.5,"claude":{"spend":0,"requests":2}},"model_spend_month":{}}"#.utf8
        )
        guard let parsed = memberSpend(memberBody) else {
            assertionFailure("member spend")
            return
        }
        assert(parsed.today == 1.5)
        assert(parsed.month == 9.25)
        assert(parsed.todayModels.first?.model.id == "gpt-4o")
        assert(parsed.todayModels.first?.cost == 1.5)
        assert(parsed.todayModels.last?.requests == 2)
        let memberLedger = Ledger(member: parsed, now: date("2026-10-24 18:00:00")!, dayStart: .utcMidnight)
        assert(memberLedger.todaySpend == 1.5)
        assert(memberLedger.monthSpend == 9.25)
        assert(memberLedger.requests.isEmpty)
        assert(memberSpend(missingKey) == nil)
        assert(Failure.http(404).message == "The spend route was not found. The proxy may be hiding it.")
        assert(Failure.http(502).message == "The gateway returned HTTP 502.")
        assert(Failure.unreachable.message == "Couldn’t reach the gateway.")

        guard case .rows(let emptyRows) = classify(Data("[]".utf8)) else {
            assertionFailure("empty rows")
            return
        }
        assert(emptyRows.isEmpty)
        assert(finish(emptyRows, now: now, version: .v1_106_2).requests.isEmpty)

        let secret = "sk-test-secret"
        let prompt = "hidden prompt"
        let emptyReport = CapabilityReport.make(
            host: reportHost("https://user:\(secret)@gateway.example.com/spend/logs/v2?api_key=\(secret)"),
            failure: nil,
            empty: true,
            checking: false,
            synced: now,
            now: now
        )
        assert(emptyReport.spend.contains("Available"))
        assert(emptyReport.spend.contains("no requests"))
        assert(!emptyReport.spend.localizedCaseInsensitiveContains("unavailable"))
        assert(emptyReport.models == "Available")
        assert(emptyReport.history == "Available")
        assert(emptyReport.action == nil)
        assert(!emptyReport.text.contains(secret))
        assert(!emptyReport.text.contains(prompt))
        assert(!emptyReport.text.contains("api_key"))
        assert(emptyReport.text.contains("gateway.example.com"))
        assert(emptyReport.text.contains("this key only"))

        let denied = Failure.http(403)
        let stale = CapabilityReport.make(
            host: "gateway.example.com",
            failure: denied,
            empty: false,
            checking: false,
            synced: now,
            now: now
        )
        assert(stale.spend == denied.message)
        assert(stale.models == denied.message)
        assert(stale.history == denied.message)
        assert(stale.synchronization.contains(denied.message))
        assert(stale.action == denied.action)
        assert(!stale.text.contains(secret))
        assert(!stale.text.contains(prompt))

        let unread = CapabilityReport.make(
            host: "gateway.example.com",
            failure: .dailyTotals,
            empty: false,
            checking: false,
            synced: nil,
            now: now
        )
        assert(unread.history == Failure.dailyTotals.message)
        assert(!unread.history.contains("Available"))
        assert(unread.synchronization == "Not synchronized yet")

        assert(HostGuard.isBlockedAddress("127.0.0.1"))
        assert(HostGuard.isBlockedAddress("10.1.2.3"))
        assert(HostGuard.isBlockedAddress("192.168.1.5"))
        assert(HostGuard.isBlockedAddress("172.16.0.1"))
        assert(HostGuard.isBlockedAddress("172.31.255.255"))
        assert(!HostGuard.isBlockedAddress("172.32.0.1"))
        assert(HostGuard.isBlockedAddress("169.254.169.254"))
        assert(HostGuard.isBlockedAddress("0.0.0.0"))
        assert(HostGuard.isBlockedAddress("::1"))
        assert(HostGuard.isBlockedAddress("fe80::1"))
        assert(HostGuard.isBlockedAddress("fd00::1"))
        assert(!HostGuard.isBlockedAddress("8.8.8.8"))
        assert(!HostGuard.isBlockedAddress("2606:4700:4700::1111"))
        assert(HostGuard.isBlockedName("metadata.google.internal"))
        assert(HostGuard.isBlockedName("metadata"))
        assert(!HostGuard.isBlockedName("llm.example.com"))
        assert(HostGuard.classify("127.0.0.1") == .blocked)
        assert(HostGuard.classify("localhost") == .blocked)
        assert(HostGuard.classify("8.8.8.8") == .allowed)

        let spend = URL(string: "https://llm.example.com/spend/logs/v2")!
        let elsewhere = URL(string: "https://other.example.com/spend/logs/v2")!
        let insecure = URL(string: "http://llm.example.com/spend/logs/v2")!
        let keyPage = "https://llm.example.com/key"
        let approvedHost = hostKey(of: spend.absoluteString)
        assert(redirectAllowed(next: spend, approvedHostKey: approvedHost, keyPageURL: keyPage))
        assert(!redirectAllowed(next: elsewhere, approvedHostKey: approvedHost, keyPageURL: keyPage))
        assert(!redirectAllowed(next: insecure, approvedHostKey: approvedHost, keyPageURL: keyPage))
        assert(!redirectAllowed(next: URL(string: keyPage)!, approvedHostKey: approvedHost, keyPageURL: keyPage))

        let profileSecret = "sk-profile-secret"
        let profile = ConnectionProfile(
            format: ConnectionProfile.formatVersion,
            organization: "Example",
            adapter: GatewayVersion.v1_106_2.rawValue,
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(
                    url: "https://llm.example.com/spend/logs/v2",
                    capability: "spend",
                    credential: "apiKey"
                ),
            ],
            keyPageURL: "https://llm.example.com/key",
            permissions: ["Read spend logs"],
            helpURL: "https://llm.example.com/help",
            scope: "this key",
            window: "Earlier of this month and 30 days ago",
            freshness: "60 seconds"
        )
        guard case .success(let encoded) = profile.encoded() else {
            assertionFailure("encode profile")
            return
        }
        let encodedText = String(decoding: encoded, as: UTF8.self)
        assert(!encodedText.contains(profileSecret))
        assert(!encodedText.contains("master"))
        guard case .success(let decoded) = ConnectionProfile.decode(encoded) else {
            assertionFailure("decode profile")
            return
        }
        assert(decoded == profile)
        guard case .success(let again) = decoded.encoded() else {
            assertionFailure("re-encode profile")
            return
        }
        guard case .success(let roundTrip) = ConnectionProfile.decode(again) else {
            assertionFailure("round trip")
            return
        }
        assert(roundTrip == profile)
        assert(!String(decoding: again, as: UTF8.self).contains(profileSecret))

        let poisoned = Data(#"{"format":1,"apiKey":"sk-profile-secret","adapter":"1.106.2"}"#.utf8)
        guard case .failure = ConnectionProfile.decode(poisoned) else {
            assertionFailure("secret field")
            return
        }
        let local = ConnectionProfile(
            format: 1,
            organization: "Local",
            adapter: "1.49.6",
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(url: "https://127.0.0.1/spend/logs", capability: "spend", credential: "apiKey"),
            ],
            keyPageURL: "https://127.0.0.1/key",
            permissions: ["Read spend logs"],
            helpURL: "",
            scope: "this key",
            window: "",
            freshness: ""
        )
        guard case .failure = local.encoded() else {
            assertionFailure("private profile")
            return
        }

        let setupSecret = "sk-setup-secret"
        let hosted = "https://files.example.com/tally.json"
        guard case .success(let link) = SetupLink.make(hostedURL: hosted) else {
            assertionFailure("setup link")
            return
        }
        assert(link.hasPrefix("tally://connect?"))
        assert(!link.contains(setupSecret))
        guard let parsedLink = URL(string: link),
              let roundTrip = SetupLink.profileURL(from: parsedLink) else {
            assertionFailure("parse setup link")
            return
        }
        assert(roundTrip.absoluteString == hosted)
        assert(SetupLink.profileURL(from: URL(string: "tally://connect")!) == nil)
        let dirty = URL(string: "tally://connect?url=\(hosted)&apiKey=\(setupSecret)")!
        let extracted = SetupLink.profileURL(from: dirty)
        assert(extracted?.absoluteString == hosted)
        assert(extracted?.absoluteString.contains(setupSecret) != true)
        guard case .failure = SetupLink.make(hostedURL: "http://files.example.com/tally.json") else {
            assertionFailure("http setup link")
            return
        }
        guard case .failure = SetupLink.make(hostedURL: "https://127.0.0.1/profile.json") else {
            assertionFailure("loopback setup link")
            return
        }
        guard case .failure = SetupLink.make(hostedURL: "https://user:\(setupSecret)@files.example.com/tally.json") else {
            assertionFailure("setup link userinfo")
            return
        }
        assert(emptyReport.text.contains("Profile host: This Mac"))
        assert(emptyReport.text.contains("Declared scope: This key"))
        let hostedReport = CapabilityReport.make(
            host: "gateway.example.com",
            profileHost: "files.example.com",
            declaredScope: "This key",
            failure: .profileMissing,
            empty: false,
            checking: false,
            synced: nil,
            now: now
        )
        assert(hostedReport.text.contains("Profile host: files.example.com"))
        assert(hostedReport.text.contains("Declared scope: This key"))
        assert(hostedReport.text.contains("Scope: this key only"))
        assert(hostedReport.text.contains(Failure.profileMissing.message))
        assert(hostedReport.text.contains("Operator: \(Failure.profileMissing.action)"))
        assert(!hostedReport.text.contains(setupSecret))

        assert(presetSpendURL("https://connect.example.com/v1", version: .connector) == "https://connect.example.com/tally/v1/requests")
        let promptSecret = "prompt-secret"
        let contract = Data(
            """
            {"format":1,"events":[
              {"id":"same","time":"2026-10-24 12:00:00","model":"gpt-4o","input":2,"output":1,"spend":1.5,"status":200,"session":"draft","messages":[{"content":"\(promptSecret)"}],"response":"hidden-body","user":"alice"},
              {"id":"same","time":"2026-10-24 12:00:01","model":"gpt-4o","input":9,"output":9,"spend":9,"status":200,"session":"other"}
            ]}
            """.utf8
        )
        guard case .success(let contractRows) = contractRows(contract) else {
            assertionFailure("connector rows")
            return
        }
        assert(contractRows.allSatisfy { $0["messages"] == nil && $0["response"] == nil && $0["user"] == nil })
        let contractRead = finish(contractRows, now: now, version: .connector)
        assert(contractRead.requests.count == 1)
        assert(contractRead.requests[0].requestID == "same")
        assert(contractRead.requests[0].cost == 1.5)
        assert(contractRead.requests[0].conversation == "draft")
        assert(!contractRead.requests[0].conversation.contains(promptSecret))
        let connectorProfile = ConnectionProfile(
            format: 1,
            organization: "Example",
            adapter: GatewayVersion.connector.rawValue,
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(
                    url: "https://connect.example.com/tally/v1/requests",
                    capability: "spend",
                    credential: "apiKey"
                ),
            ],
            keyPageURL: "https://connect.example.com/keys",
            permissions: ["Read spend logs"],
            helpURL: "",
            scope: "this user",
            window: "Earlier of this month and 30 days ago",
            freshness: "60 seconds"
        )
        guard case .success(let connectorEncoded) = connectorProfile.encoded() else {
            assertionFailure("connector profile")
            return
        }
        let connectorText = String(decoding: connectorEncoded, as: UTF8.self)
        assert(connectorText.contains("connect.example.com"))
        assert(!connectorText.contains("10.1.2.3"))
        assert(!connectorText.contains(promptSecret))
        assert(!encodedText.contains("authorizationURL"))
        assert(!encodedText.contains("access_token"))
        assert(!encodedText.contains("refresh_token"))
        let privateConnector = ConnectionProfile(
            format: 1,
            organization: "Local",
            adapter: "connector",
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(url: "https://10.1.2.3/tally/v1/requests", capability: "spend", credential: "apiKey"),
            ],
            keyPageURL: "https://connect.example.com/keys",
            permissions: ["Read spend logs"],
            helpURL: "",
            scope: "this key",
            window: "",
            freshness: ""
        )
        guard case .failure = privateConnector.encoded() else {
            assertionFailure("private connector")
            return
        }

        let legacy = Data(
            """
            {"format":1,"organization":"Example","adapter":"1.106.2","auth":"apiKey","endpoints":[{"url":"https://llm.example.com/spend/logs/v2","capability":"spend","credential":"apiKey"}],"keyPageURL":"https://llm.example.com/key","permissions":["Read spend logs"],"helpURL":"https://llm.example.com/help","scope":"this key","window":"Earlier of this month and 30 days ago","freshness":"60 seconds"}
            """.utf8
        )
        guard case .success(let legacyProfile) = ConnectionProfile.decode(legacy) else {
            assertionFailure("legacy profile")
            return
        }
        assert(legacyProfile.authorizationURL == nil)
        assert(legacyProfile.tokenURL == nil)
        assert(legacyProfile.clientID == nil)
        assert(legacyProfile == profile)

        var incomplete = profile
        incomplete.authorizationURL = "https://operator.example.com/authorize"
        guard case .failure(let incompleteFailure) = incomplete.encoded() else {
            assertionFailure("incomplete exchange")
            return
        }
        assert(incompleteFailure.message == "This profile’s sign-in exchange is incomplete.")
        var exchange = profile
        exchange.authorizationURL = "https://operator.example.com/authorize"
        exchange.tokenURL = "https://operator.example.com/token"
        exchange.revocationURL = "https://operator.example.com/revoke"
        exchange.clientID = "tally"
        guard case .success(let exchangeData) = exchange.encoded() else {
            assertionFailure("exchange profile")
            return
        }
        let exchangeText = String(decoding: exchangeData, as: UTF8.self)
        assert(exchangeText.contains("authorizationURL"))
        assert(exchangeText.contains("\"clientID\" : \"tally\"") || exchangeText.contains("\"clientID\": \"tally\""))
        assert(!exchangeText.contains("access_token"))
        assert(!exchangeText.contains("refresh_token"))
        assert(!exchangeText.contains("sk-master"))
        var privateExchange = exchange
        privateExchange.tokenURL = "https://127.0.0.1/token"
        guard case .failure = privateExchange.encoded() else {
            assertionFailure("private token url")
            return
        }

        let verifier = String(repeating: "a", count: 43)
        let made = TrackingAuth.makeChallenge(verifier: verifier)
        assert(made.challenge == "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA")
        guard let authorize = TrackingAuth.authorizeURL(
            endpoint: "https://operator.example.com/authorize",
            clientID: "tally",
            state: "state-1",
            challenge: made.challenge
        ), let authorizeItems = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems else {
            assertionFailure("authorize url")
            return
        }
        assert(authorizeItems.first { $0.name == "code_challenge" }?.value == made.challenge)
        assert(authorizeItems.first { $0.name == "code_challenge_method" }?.value == "S256")
        assert(authorizeItems.first { $0.name == "scope" }?.value == "spend.read")
        let authorizeNames = Set(authorizeItems.map(\.name))
        assert(authorizeNames == [
            "response_type", "client_id", "redirect_uri", "state",
            "code_challenge", "code_challenge_method", "scope",
        ])
        let authorizeText = authorize.absoluteString
        assert(!authorizeText.contains("sk-master"))
        assert(!authorizeText.contains("sk-existing"))
        assert(!authorizeText.contains("api_key"))
        assert(!authorizeText.contains("master_key"))
        let codeForm = TrackingAuth.codeForm(clientID: "tally", code: "code-1", verifier: verifier)
        assert(codeForm.contains("code_verifier=\(verifier)"))
        assert(codeForm.contains("redirect_uri=tally%3A%2F%2Fcallback"))
        assert(!codeForm.contains("sk-master"))
        assert(!codeForm.contains("api_key"))
        assert(!codeForm.contains("master_key"))
        let refreshForm = TrackingAuth.refreshForm(clientID: "tally", refreshToken: "refresh-1")
        assert(refreshForm.contains("grant_type=refresh_token"))
        assert(!refreshForm.contains("sk-master"))
        assert(!refreshForm.contains("api_key"))
        guard case .failure = TrackingAuth.parse(Data(#"{"access_token":"sk-issued"}"#.utf8)) else {
            assertionFailure("missing expiry")
            return
        }
        guard case .success(let issued) = TrackingAuth.parse(Data(
            #"{"access_token":"tk-issued","expires_in":60,"refresh_token":"rt-1","scope":"spend.read"}"#.utf8
        )) else {
            assertionFailure("parse token")
            return
        }
        assert(issued.scope == "this key")
        assert(issued.expiresIn == 60)
        assert(issued.accessToken == "tk-issued")
        guard case .success(let team) = TrackingAuth.parse(Data(
            #"{"access_token":"tk-issued","expires_in":60,"scope":"team"}"#.utf8
        )) else {
            assertionFailure("parse team")
            return
        }
        assert(team.scope == "team")
        assert(team.refreshToken == nil)
        assert(TrackingAuth.isExpired(expiry: 100, now: Date(timeIntervalSince1970: 100)))
        assert(!TrackingAuth.isExpired(expiry: 100, now: Date(timeIntervalSince1970: 99)))
        assert(!TrackingAuth.isExpired(expiry: 0, now: Date(timeIntervalSince1970: 10_000)))

        let userReport = CapabilityReport.make(
            host: "gateway.example.com",
            declaredScope: "This user",
            failure: nil,
            empty: false,
            checking: false,
            synced: now,
            now: now
        )
        assert(userReport.text.contains("Scope: this user"))
        assert(!userReport.text.contains("Scope: this key only"))
        let teamReport = CapabilityReport.make(
            host: "gateway.example.com",
            declaredScope: "Team",
            failure: nil,
            empty: true,
            checking: false,
            synced: now,
            now: now
        )
        assert(teamReport.text.contains("Scope: an authorized team"))
    }
    #endif

    private enum Body {
        case page([[String: Any]], Int)
        case rows([[String: Any]])
        case dailyTotals
        case loginPage
        case unsupported
    }

    /// One public read. Prompt and response bodies are dropped before the row is kept.
    private static func fetchContract(
        components: URLComponents,
        apiKey: String,
        approvedHostKey: String,
        keyPageURL: String,
        now: Date
    ) async -> Result<Read, Failure> {
        var components = components
        let start = windowStart(now)
        components.queryItems = [
            URLQueryItem(name: "start", value: timestamp(start)),
            URLQueryItem(name: "end", value: timestamp(now)),
        ]
        guard let url = components.url else { return .failure(.invalidURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch await send(request, approvedHostKey: approvedHostKey, keyPageURL: keyPageURL) {
        case .data(let data):
            switch contractRows(data) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let rows):
                return .success(finish(rows, now: now, version: .connector))
            }
        case .status(let code, _):
            return .failure(.http(code))
        case .redirect:
            return .failure(.redirected)
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    static func contractRows(_ data: Data) -> Result<[[String: Any]], Failure> {
        if isHTML(data) { return .failure(.loginPage) }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return .failure(.unsupported)
        }
        let format = (object["format"] as? NSNumber)?.intValue ?? 0
        guard format == 1, let events = object["events"] as? [[String: Any]] else {
            return .failure(.unsupported)
        }
        let rows: [[String: Any]] = events.map { event in
            [
                "request_id": text(event["id"]),
                "startTime": text(event["time"]),
                "model": text(event["model"]),
                "prompt_tokens": number(event["input"]),
                "completion_tokens": number(event["output"]),
                "spend": number(event["spend"]),
                "status": event["status"] ?? 200,
                "session_id": text(event["session"]),
            ]
        }
        guard rows.allSatisfy(isRequestRow) else { return .failure(.unsupported) }
        return .success(rows)
    }

    private static func classify(_ data: Data) -> Body {
        if isHTML(data) { return .loginPage }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .unsupported }
        if let page = object as? [String: Any] {
            guard let rows = page["data"] as? [[String: Any]] else { return .unsupported }
            if !rows.isEmpty, rows.allSatisfy(isDailyTotal) { return .dailyTotals }
            if rows.allSatisfy(isRequestRow) {
                return .page(rows, max(Int(number(page["total_pages"])), 1))
            }
            return .unsupported
        }
        if let list = object as? [Any] {
            let rows = list.compactMap { $0 as? [String: Any] }
            guard rows.count == list.count else { return .unsupported }
            if rows.isEmpty || rows.allSatisfy(isRequestRow) { return .rows(rows) }
            if rows.allSatisfy(isDailyTotal) { return .dailyTotals }
            return .unsupported
        }
        return .unsupported
    }

    private static func isHTML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(256), encoding: .utf8) else { return false }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<") || trimmed.contains("<html")
    }

    private static func isRequestRow(_ row: [String: Any]) -> Bool {
        guard let identifier = row["request_id"] as? String else { return false }
        return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isDailyTotal(_ row: [String: Any]) -> Bool {
        guard !isRequestRow(row), row["spend"] != nil else { return false }
        return row["users"] != nil || row["models"] != nil
    }

    private static func finish(_ rows: [[String: Any]], now: Date, version: GatewayVersion) -> Read {
        var requests = deduped(parse(rows))
        if version == .v1_49_6 || version == .connector {
            let start = windowStart(now)
            requests = requests.filter { $0.time >= start && $0.time <= now }
        }
        var truncated = false
        if requests.count > rowCap {
            requests.sort { $0.time > $1.time }
            requests = Array(requests.prefix(rowCap))
            truncated = true
        }
        return Read(requests: requests, truncated: truncated)
    }

    private static func deduped(_ requests: [UsageRequest]) -> [UsageRequest] {
        var seen: Set<String> = []
        var kept: [UsageRequest] = []
        for request in requests {
            if request.requestID.isEmpty || seen.insert(request.requestID).inserted {
                kept.append(request)
            }
        }
        return kept
    }

    /// Spend-log clocks are UTC. `messages` and `response` are left unread.
    private static func parse(_ rows: [[String: Any]]) -> [UsageRequest] {
        rows.enumerated().map { index, row in
            UsageRequest(
                id: index + 1,
                time: date(row["startTime"] ?? row["start_time"]) ?? Date(),
                model: AIModel(text(row["model"])),
                conversation: conversation(row),
                input: Int(number(row["prompt_tokens"])),
                output: Int(number(row["completion_tokens"])),
                cost: number(row["spend"]),
                status: statusCode(row["status"]),
                requestID: text(row["request_id"])
            )
        }
    }

    private static func conversation(_ row: [String: Any]) -> String {
        if let session = row["session_id"] as? String {
            let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let tags = row["request_tags"] as? [String] ?? []
        if let tag = tags.first(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("User-Agent")
        }) {
            return tag
        }
        return "—"
    }

    private static func statusCode(_ value: Any?) -> Int {
        if let string = value as? String {
            if let code = Int(string) { return code }
            if string.isEmpty || string.lowercased() == "success" { return 200 }
            return 500
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 200
    }

    private static func text(_ value: Any?) -> String {
        (value as? String) ?? ""
    }

    private static func number(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string) ?? 0
        default:
            return 0
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let parsed = ISO8601DateFormatter().date(from: string) { return parsed }
        // shortcut: spend-log timestamps are UTC, switch if a gateway sends local time
        let parts = string.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-")
        let clock = parts[1].split(separator: ":")
        guard day.count == 3, clock.count == 3,
              let year = Int(day[0]), let month = Int(day[1]), let dayNumber = Int(day[2]),
              let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(
            year: year, month: month, day: dayNumber, hour: hour, minute: minute, second: second
        ))
    }

    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func hostKey(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return "" }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(host.lowercased())|\(port)"
    }

    static func origin(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else { return "" }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    static func redirectAllowed(next: URL, approvedHostKey: String, keyPageURL: String) -> Bool {
        guard next.scheme == "https", !approvedHostKey.isEmpty else { return false }
        guard hostKey(of: next.absoluteString) == approvedHostKey else { return false }
        if sameDestination(next.absoluteString, keyPageURL) { return false }
        return true
    }

    /// Public https hosts only. A private or metadata address never receives the key.
    static func screen(
        spendURL: String,
        keyPageURL: String,
        helpURL: String = "",
        authorizationURL: String = "",
        tokenURL: String = "",
        revocationURL: String = ""
    ) -> Failure? {
        let spend = spendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: spend), url.scheme == "https", url.host?.isEmpty == false else {
            return .invalidURL
        }
        if sameDestination(spend, keyPageURL) { return .sameDestination }
        if let failure = HostGuard.failure(for: url.host ?? "") { return failure }
        if let failure = screenLink(keyPageURL, label: "key page URL") { return failure }
        if let failure = screenLink(helpURL, label: "help URL") { return failure }
        if let failure = screenLink(authorizationURL, label: "authorization URL") { return failure }
        if let failure = screenLink(tokenURL, label: "token URL") { return failure }
        if let failure = screenLink(revocationURL, label: "revocation URL") { return failure }
        return nil
    }

    static func screenLink(_ raw: String, label: String) -> Failure? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty else {
            return Failure(message: "Enter an https \(label).", action: "Use an https \(label).")
        }
        return HostGuard.failure(for: host)
    }

    static func reportHost(_ spendURL: String) -> String {
        let trimmed = spendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host,
              !host.isEmpty else { return "unknown" }
        if let port = components.port, port != 443 {
            return "\(host):\(port)"
        }
        return host
    }

    static func dayStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func windowStart(_ now: Date) -> Date {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let thirtyDays = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        return min(monthStart, thirtyDays)
    }

    private static func identity(_ url: URL) -> String {
        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        return "\(url.scheme ?? "")|\(url.host?.lowercased() ?? "")|\(port)|\(path)"
    }

    private enum Fetch {
        case data(Data)
        case status(Int, Data)
        case redirect
        case unreachable
    }

    /// Downloads a hosted profile. Sends no Authorization header.
    static func downloadProfile(from raw: String) async -> Result<ConnectionProfile, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return .failure(Failure(
                message: "Enter an https address for the hosted profile.",
                action: "Host the exported JSON at an https address."
            ))
        }
        if HostGuard.isBlockedName(host) || (HostGuard.isNumeric(host) && HostGuard.isBlockedAddress(host)) {
            return .failure(.profilePrivate)
        }
        switch HostGuard.classify(host) {
        case .allowed:
            break
        case .blocked:
            return .failure(.profilePrivate)
        case .unresolved:
            return .failure(Failure(
                message: "Couldn’t resolve the profile host. It was not downloaded.",
                action: "Check the profile address and try again."
            ))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch await send(request, approvedHostKey: hostKey(of: url.absoluteString), keyPageURL: "") {
        case .data(let data):
            // shortcut: the body is read fully, then rejected over 64 KB — stream the cap if profiles grow
            if data.count > 65_536 { return .failure(.profileTooLarge) }
            switch ConnectionProfile.decode(data) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let profile):
                if let failure = screen(
                    spendURL: profile.spendURL,
                    keyPageURL: profile.keyPageURL,
                    helpURL: profile.helpURL,
                    authorizationURL: profile.authorizationURL ?? "",
                    tokenURL: profile.tokenURL ?? "",
                    revocationURL: profile.revocationURL ?? ""
                ) {
                    return .failure(failure)
                }
                return .success(profile)
            }
        case .status(let code, _):
            switch code {
            case 401, 403: return .failure(.profileRefused)
            case 404: return .failure(.profileMissing)
            default: return .failure(.profileHTTP(code))
            }
        case .redirect:
            return .failure(.profileRedirected)
        case .unreachable:
            return .failure(.profileUnreachable)
        }
    }

    /// Posts the code or refresh token. Sends no Authorization header and no client secret.
    static func redeem(tokenURL: String, form: String) async -> Result<TrackingAuth.Credential, Failure> {
        let trimmed = tokenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(Failure(
                message: "This gateway needs an operator integration.",
                action: "Add the token URL, or paste a tracking key."
            ))
        }
        if let failure = screenLink(trimmed, label: "token URL") { return .failure(failure) }
        guard let url = URL(string: trimmed) else { return .failure(.invalidURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch await send(request, approvedHostKey: hostKey(of: trimmed), keyPageURL: "") {
        case .data(let data):
            return TrackingAuth.parse(data)
        case .status:
            return .failure(TrackingAuth.rejected)
        case .redirect:
            return .failure(.redirected)
        case .unreachable:
            return .failure(.unreachable)
        }
    }

    /// Best effort. The caller has already checked that the revocation host is the host that issued the key.
    static func revoke(revocationURL: String, token: String, pinnedHost: String) async {
        let trimmed = revocationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !token.isEmpty, !pinnedHost.isEmpty else { return }
        guard hostKey(of: trimmed) == pinnedHost else { return }
        guard screenLink(trimmed, label: "revocation URL") == nil, let url = URL(string: trimmed) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data(TrackingAuth.revokeForm(token: token).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = await send(request, approvedHostKey: pinnedHost, keyPageURL: "")
    }

    private static func send(_ request: URLRequest, approvedHostKey: String, keyPageURL: String) async -> Fetch {
        let pin = RedirectPin(approvedHostKey: approvedHostKey, keyPageURL: keyPageURL)
        let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return pin.rejected ? .redirect : .unreachable
        }
        if pin.rejected || (300..<400).contains(http.statusCode) { return .redirect }
        guard (200..<300).contains(http.statusCode) else { return .status(http.statusCode, data) }
        return .data(data)
    }

    /// A personal key is refused on the admin spend log. Read `{origin}/user/daily_spend` instead.
    private static func fetchMember(spendURL: String, apiKey: String, keyPageURL: String) async -> Result<Read, Failure> {
        let origin = origin(of: spendURL)
        guard var components = URLComponents(string: origin),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            return .failure(.memberRoute)
        }
        components.path = "/user/daily_spend"
        components.query = nil
        components.fragment = nil
        guard let url = components.url, let trimmed = components.string else {
            return .failure(.memberRoute)
        }
        if sameDestination(trimmed, keyPageURL) { return .failure(.sameDestination) }
        if let failure = screen(spendURL: trimmed, keyPageURL: keyPageURL) {
            return .failure(failure)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch await send(request, approvedHostKey: hostKey(of: trimmed), keyPageURL: keyPageURL) {
        case .data(let data):
            guard let spend = memberSpend(data) else { return .failure(.memberRoute) }
            return .success(Read(requests: [], truncated: false, role: .member, member: spend))
        case .status, .redirect, .unreachable:
            return .failure(.memberRoute)
        }
    }

    /// LiteLLM names the role in the admin refusal. A missing or malformed key does not.
    static func roleRefusal(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let message: String
        if let error = object["error"] as? [String: Any] {
            message = text(error["message"])
        } else {
            message = text(object["detail"])
        }
        let lower = message.lowercased()
        return lower.contains("proxy admin") || lower.contains("your role=")
    }

    static func memberSpend(_ data: Data) -> MemberSpend? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              object["daily_spend"] != nil,
              object["monthly_spend"] != nil else { return nil }
        return MemberSpend(
            today: number(object["daily_spend"]),
            month: number(object["monthly_spend"]),
            todayModels: modelTotals(object["model_spend_today"]),
            monthModels: modelTotals(object["model_spend_month"])
        )
    }

    private static func modelTotals(_ value: Any?) -> [ModelTotal] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.compactMap { key, raw in
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let cost: Double
            let requests: Int
            if let row = raw as? [String: Any] {
                cost = number(row["spend"] ?? row["cost"] ?? row["total_spend"])
                requests = Int(number(row["requests"] ?? row["count"]))
            } else {
                cost = number(raw)
                requests = 0
            }
            return ModelTotal(model: AIModel(name), requests: requests, cost: cost)
        }
        .sorted { $0.cost > $1.cost }
    }
}

private final class RedirectPin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let approvedHostKey: String
    let keyPageURL: String
    private let lock = NSLock()
    private var sawRejection = false

    init(approvedHostKey: String, keyPageURL: String) {
        self.approvedHostKey = approvedHostKey
        self.keyPageURL = keyPageURL
    }

    var rejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawRejection
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let next = request.url,
              GatewayClient.redirectAllowed(next: next, approvedHostKey: approvedHostKey, keyPageURL: keyPageURL) else {
            lock.lock()
            sawRejection = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct CapabilityReport: Equatable {
    var host: String
    var profileHost: String
    var declaredScope: String
    var spend: String
    var models: String
    var history: String
    var synchronization: String
    var action: String?

    var text: String {
        var lines = [
            "Host: \(host)",
            "Profile host: \(profileHost)",
            "Declared scope: \(declaredScope)",
            "Scope: \(Self.scopePhrase(declaredScope))",
            "Spend and tokens: \(spend)",
            "Models: \(models)",
            "Request history: \(history)",
            "Last synchronization: \(synchronization)",
        ]
        if let action {
            lines.append("Operator: \(action)")
        }
        return lines.joined(separator: "\n")
    }

    static func scopePhrase(_ declaredScope: String) -> String {
        switch declaredScope {
        case "This user": "this user"
        case "Team": "an authorized team"
        default: "this key only"
        }
    }

    static func make(
        host: String,
        profileHost: String = "This Mac",
        declaredScope: String = "This key",
        failure: GatewayClient.Failure?,
        empty: Bool,
        checking: Bool,
        synced: Date?,
        now: Date
    ) -> CapabilityReport {
        let sentence: String
        if let failure {
            sentence = failure.message
        } else if synced == nil {
            sentence = checking ? "Checking the gateway." : "Not synchronized yet"
        } else if empty {
            sentence = "Available, this key only, no requests in this window."
        } else {
            let start = GatewayClient.dayStamp(GatewayClient.windowStart(now))
            sentence = "Available, this key only, since \(start)."
        }
        let waiting = failure != nil || synced == nil
        let synchronization: String
        if let failure, let synced {
            synchronization = "\(Format.clock(synced)), then \(failure.message)"
        } else if let synced {
            synchronization = Format.clock(synced)
        } else {
            synchronization = "Not synchronized yet"
        }
        return CapabilityReport(
            host: host,
            profileHost: profileHost,
            declaredScope: declaredScope,
            spend: sentence,
            models: waiting ? sentence : "Available",
            history: waiting ? sentence : "Available",
            synchronization: synchronization,
            action: failure?.action
        )
    }
}

enum HostGuard {
    enum Verdict: Equatable {
        case allowed
        case blocked
        case unresolved
    }

    static func failure(for host: String) -> GatewayClient.Failure? {
        switch classify(host) {
        case .allowed: nil
        case .blocked: .privateAddress
        case .unresolved: .unresolved
        }
    }

    static func classify(_ host: String) -> Verdict {
        let name = normalized(host)
        if name.isEmpty || isBlockedName(name) { return .blocked }
        if isNumeric(name) { return isBlockedAddress(name) ? .blocked : .allowed }
        guard let addresses = lookup(name), !addresses.isEmpty else { return .unresolved }
        if addresses.contains(where: isBlockedAddress) { return .blocked }
        return .allowed
    }

    static func isBlockedName(_ host: String) -> Bool {
        let name = normalized(host)
        return name.isEmpty || name == "metadata" || name == "instance-data" || name == "metadata.google.internal"
    }

    static func isNumeric(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, stripZone(host), &v6) == 1
    }

    static func isBlockedAddress(_ presentation: String) -> Bool {
        let bare = stripZone(presentation)
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return ipv4Blocked(bytes)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return true }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return ipv6Blocked(bytes)
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func stripZone(_ host: String) -> String {
        host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
    }

    private static func ipv4Blocked(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        let a = bytes[0]
        let b = bytes[1]
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(Int(b)) { return true }
        if a == 192 && b == 168 { return true }
        if bytes == [255, 255, 255, 255] { return true }
        return false
    }

    private static func ipv6Blocked(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped { return ipv4Blocked(Array(bytes.suffix(4))) }
        return false
    }

    private static func lookup(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                found.append(String(cString: buffer))
            }
            cursor = current.pointee.ai_next
        }
        return found
    }
}

struct ConnectionProfile: Codable, Equatable {
    static let formatVersion = 1

    var format: Int
    var organization: String
    var adapter: String
    var auth: String
    var endpoints: [Endpoint]
    var keyPageURL: String
    var permissions: [String]
    var helpURL: String
    var scope: String
    var window: String
    var freshness: String
    var authorizationURL: String? = nil
    var tokenURL: String? = nil
    var revocationURL: String? = nil
    var clientID: String? = nil

    struct Endpoint: Codable, Equatable {
        var url: String
        var capability: String
        var credential: String
    }

    var spendURL: String { endpoints.first?.url ?? "" }

    func encoded() -> Result<Data, GatewayClient.Failure> {
        if let failure = validated() { return .failure(failure) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return .success(try encoder.encode(self))
        } catch {
            return .failure(GatewayClient.Failure(
                message: "Couldn’t write the profile.",
                action: "Try the export again."
            ))
        }
    }

    static func decode(_ data: Data) -> Result<ConnectionProfile, GatewayClient.Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(GatewayClient.Failure(
                message: "This file is not a connection profile.",
                action: "Choose the JSON profile exported from Tally."
            ))
        }
        if containsSecret(object) {
            return .failure(GatewayClient.Failure(
                message: "This profile contains a secret. Remove it and share the file again.",
                action: "Delete the key from the file. Each person uses their own."
            ))
        }
        guard let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: data) else {
            return .failure(GatewayClient.Failure(
                message: "This file is not a connection profile.",
                action: "Choose the JSON profile exported from Tally."
            ))
        }
        if let failure = profile.validated() { return .failure(failure) }
        return .success(profile)
    }

    func validated() -> GatewayClient.Failure? {
        if format != Self.formatVersion {
            return GatewayClient.Failure(
                message: "This profile version is not supported.",
                action: "Ask the operator for a current Tally profile."
            )
        }
        if GatewayVersion(rawValue: adapter) == nil {
            return GatewayClient.Failure(
                message: "This profile names an unsupported adapter.",
                action: "Use LiteLLM 1.49.6, LiteLLM 1.106.2, or a connector."
            )
        }
        if auth != "apiKey" {
            return GatewayClient.Failure(
                message: "This profile uses an authentication method Tally does not support.",
                action: "Use a personal API key."
            )
        }
        guard endpoints.count == 1, let endpoint = endpoints.first else {
            return GatewayClient.Failure(
                message: "This profile must name one spend endpoint.",
                action: "Include the spend-log URL only."
            )
        }
        if endpoint.capability != "spend" || endpoint.credential != "apiKey" {
            return GatewayClient.Failure(
                message: "This profile asks Tally to call an endpoint it does not use.",
                action: "Name the spend-log URL and the apiKey slot."
            )
        }
        if let failure = literal(endpoint.url, label: "spend URL") { return failure }
        if let failure = literal(keyPageURL, label: "key page URL", emptyAllowed: true) { return failure }
        if !keyPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           GatewayClient.sameDestination(endpoint.url, keyPageURL) {
            return .sameDestination
        }
        if let failure = literal(helpURL, label: "help URL", emptyAllowed: true) { return failure }
        let authorization = authorizationURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = tokenURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let revocation = revocationURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let client = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !authorization.isEmpty || !token.isEmpty || !client.isEmpty {
            if authorization.isEmpty || token.isEmpty || client.isEmpty {
                return GatewayClient.Failure(
                    message: "This profile’s sign-in exchange is incomplete.",
                    action: "Include the authorization URL, the token URL, and the client id."
                )
            }
        }
        if let failure = literal(authorization, label: "authorization URL", emptyAllowed: true) { return failure }
        if let failure = literal(token, label: "token URL", emptyAllowed: true) { return failure }
        if let failure = literal(revocation, label: "revocation URL", emptyAllowed: true) { return failure }
        if organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GatewayClient.Failure(
                message: "This profile needs an organization name.",
                action: "Add the organization name."
            )
        }
        let named = permissions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if named.isEmpty || named.contains("") {
            return GatewayClient.Failure(
                message: "This profile needs the access it is requesting.",
                action: "Name the permission, such as reading spend logs."
            )
        }
        if !["this key", "this user", "team"].contains(scope) {
            return GatewayClient.Failure(
                message: "This profile’s scope must be this key, this user, or team.",
                action: "Set the scope to one of those."
            )
        }
        return nil
    }

    private func literal(_ raw: String, label: String, emptyAllowed: Bool = false) -> GatewayClient.Failure? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return emptyAllowed ? nil : .invalidURL
        }
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host, !host.isEmpty else {
            return GatewayClient.Failure(message: "Enter an https \(label).", action: "Use an https \(label).")
        }
        if HostGuard.isBlockedName(host) || (HostGuard.isNumeric(host) && HostGuard.isBlockedAddress(host)) {
            return .privateAddress
        }
        return nil
    }

    private static func containsSecret(_ json: Any) -> Bool {
        let banned: Set<String> = [
            "apikey", "api_key", "token", "secret", "password", "authorization",
            "bearer", "master_key", "masterkey", "access_token", "refresh_token",
        ]
        if let object = json as? [String: Any] {
            for (key, value) in object {
                if banned.contains(key.lowercased()) || containsSecret(value) { return true }
            }
            return false
        }
        if let list = json as? [Any] {
            return list.contains(where: containsSecret)
        }
        return false
    }
}

enum SetupLink {
    /// Structural only. DNS happens when the profile is downloaded.
    static func make(hostedURL: String) -> Result<String, GatewayClient.Failure> {
        guard let components = httpsComponents(hostedURL) else {
            return .failure(GatewayClient.Failure(
                message: "Enter an https address for the hosted profile.",
                action: "Host the exported JSON at an https address."
            ))
        }
        if components.user != nil || components.password != nil {
            return .failure(GatewayClient.Failure(
                message: "The profile address must not include a username or password.",
                action: "Remove the username and password from the address."
            ))
        }
        if let host = components.host, HostGuard.isBlockedName(host) || (HostGuard.isNumeric(host) && HostGuard.isBlockedAddress(host)) {
            return .failure(.profilePrivate)
        }
        var link = URLComponents()
        link.scheme = "tally"
        link.host = "connect"
        link.queryItems = [URLQueryItem(name: "url", value: components.string ?? hostedURL)]
        guard let string = link.string else {
            return .failure(GatewayClient.Failure(
                message: "Couldn’t copy the setup link.",
                action: "Check the hosted profile address and try again."
            ))
        }
        return .success(string)
    }

    /// The `url` query item only. Other query items, including a key, are ignored.
    static func profileURL(from link: URL) -> URL? {
        guard link.scheme?.lowercased() == "tally", link.host?.lowercased() == "connect" else { return nil }
        guard let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value,
              let components = httpsComponents(raw),
              components.user == nil,
              components.password == nil else { return nil }
        return components.url
    }

    private static func httpsComponents(_ raw: String) -> URLComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else { return nil }
        return components
    }
}
