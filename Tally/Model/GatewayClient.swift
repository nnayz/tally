import Foundation

enum GatewayVersion: String, CaseIterable, Identifiable {
    case v1_106_2 = "1.106.2"
    case v1_49_6 = "1.49.6"

    var id: String { rawValue }

    var title: String { "LiteLLM \(rawValue)" }

    /// Spend logs are mounted on the gateway origin. A client base such as `/v1` is not part of the path.
    var spendPath: String {
        switch self {
        case .v1_106_2: "/spend/logs/v2"
        case .v1_49_6: "/spend/logs"
        }
    }
}

enum GatewayClient {
    struct Failure: Error {
        var message: String
    }

    struct Read {
        var requests: [UsageRequest]
        var truncated: Bool
    }

    static let rowCap = 2_000
    static let truncationNotice = "Showing the first 2,000 requests in this window."

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
            return .failure(Failure(message: "Enter an https spend URL."))
        }
        if sameDestination(trimmed, keyPageURL) {
            return .failure(Failure(message: "The spend URL and the key page must be different."))
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
                return .failure(Failure(message: "Enter an https spend URL."))
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            switch await send(request) {
            case .data(let data):
                switch classify(data) {
                case .loginPage:
                    return .failure(Failure(message: "The gateway returned a login page, not spend data."))
                case .dailyTotals:
                    return .failure(Failure(message: "This URL returned daily totals, not requests."))
                case .unsupported:
                    return .failure(Failure(message: "This response is not a supported spend log."))
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
            case .unauthorized:
                return .failure(Failure(message: "The gateway rejected this API key."))
            case .forbidden:
                return .failure(Failure(message: "This key cannot read spend logs."))
            case .failed:
                return .failure(Failure(message: "Couldn’t reach the gateway."))
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
    }
    #endif

    private enum Body {
        case page([[String: Any]], Int)
        case rows([[String: Any]])
        case dailyTotals
        case loginPage
        case unsupported
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
        if version == .v1_49_6 {
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

    private static func windowStart(_ now: Date) -> Date {
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
        case unauthorized
        case forbidden
        case failed
    }

    private static func send(_ request: URLRequest) async -> Fetch {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 401 { return .unauthorized }
        if http.statusCode == 403 { return .forbidden }
        guard (200..<300).contains(http.statusCode) else { return .failed }
        return .data(data)
    }
}
