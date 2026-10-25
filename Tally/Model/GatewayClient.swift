import Foundation

enum GatewayClient {
    struct Failure: Error {
        var message: String
    }

    static func fetch(baseURL: String, apiKey: String, now: Date = Date()) async -> Result<[UsageRequest], Failure> {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            return .failure(Failure(message: "Enter an https gateway URL."))
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        path += "/spend/logs/v2"
        components.path = path

        let start = windowStart(now)
        var page = 1
        var rows: [[String: Any]] = []
        // shortcut: stop after 10 pages (2,000 rows), raise the cap if a month no longer fits
        while page <= 10 {
            components.queryItems = [
                URLQueryItem(name: "start_date", value: timestamp(start)),
                URLQueryItem(name: "end_date", value: timestamp(now)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: "200"),
            ]
            guard let url = components.url else {
                return .failure(Failure(message: "Enter an https gateway URL."))
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            switch await send(request) {
            case .data(let data):
                guard let pageRows = pageRows(from: data) else {
                    return .failure(Failure(message: "Couldn’t reach the gateway."))
                }
                rows.append(contentsOf: pageRows.rows)
                if pageRows.rows.isEmpty || page >= pageRows.totalPages {
                    return .success(parse(rows))
                }
                page += 1
            case .unauthorized:
                return .failure(Failure(message: "The gateway rejected this API key."))
            case .forbidden:
                return .failure(Failure(message: "This key cannot read spend logs."))
            case .failed:
                return .failure(Failure(message: "Couldn’t reach the gateway."))
            }
        }
        return .success(parse(rows))
    }

    #if DEBUG
    static func selfCheck() {
        let data = Data(
            """
            {"data":[
              {"request_id":"a","startTime":"2026-10-24 12:00:00","model":"anthropic/claude-sonnet","prompt_tokens":10,"completion_tokens":4,"spend":0.5,"status":"success","session_id":"draft","request_tags":["User-Agent: test"],"messages":[{"role":"user","content":"secret"}]},
              {"request_id":"b","start_time":"2026-10-24 13:00:00","model":"gpt-4o","prompt_tokens":2,"completion_tokens":1,"spend":0.25,"status":"failure","session_id":"","request_tags":["User-Agent: x","review"],"response":"hidden"}
            ],"total_pages":1}
            """.utf8
        )
        let parsed = parse(pageRows(from: data)?.rows ?? [])
        assert(parsed.count == 2)
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
    }
    #endif

    private struct Page {
        var rows: [[String: Any]]
        var totalPages: Int
    }

    private static func pageRows(from data: Data) -> Page? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return nil }
        let total = number(object["total_pages"])
        return Page(rows: rows, totalPages: max(Int(total), 1))
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
                status: statusCode(row["status"])
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
        if let date = ISO8601DateFormatter().date(from: string) { return date }
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
