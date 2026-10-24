import Foundation
import SQLite3

enum WidgetSource: String, CaseIterable, Identifiable {
    case gateway
    case codex
    case claude
    case grok
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gateway: "Gateway"
        case .codex: "ChatGPT / Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }

    /// Short name for the menu bar, where width is the constraint.
    var menuLabel: String {
        switch self {
        case .gateway: "Gateway"
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }
}

struct QuotaReading: Equatable {
    var percent: Double?
    var detail: String
    /// No local sign-in. Drop any previous number instead of keeping it.
    var unavailable: Bool

    static func ready(_ percent: Double, _ detail: String) -> QuotaReading {
        QuotaReading(percent: percent, detail: detail, unavailable: false)
    }

    static func missing(_ detail: String) -> QuotaReading {
        QuotaReading(percent: nil, detail: detail, unavailable: true)
    }

    static func failed(_ detail: String) -> QuotaReading {
        QuotaReading(percent: nil, detail: detail, unavailable: false)
    }
}

enum QuotaReader {
    static func read(_ source: WidgetSource) async -> QuotaReading {
        switch source {
        case .gateway:
            return .missing("")
        case .codex:
            return await readCodex()
        case .claude:
            return readClaude()
        case .grok:
            return await readGrok()
        case .cursor:
            return await readCursor()
        }
    }

    #if DEBUG
    static func selfCheck() {
        let codex = parseCodex(Data(
            #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":27,"limit_window_seconds":18000,"reset_at":1782770922},"secondary_window":{"used_percent":4,"limit_window_seconds":604800,"reset_at":1783357722}}}"#
                .utf8
        ))
        assert(codex.percent == 27)
        assert(codex.detail.hasPrefix("Plus · 5h · week 4% · resets "))

        let claude = parseClaude(jsonObject(Data(
            #"{"cachedUsageUtilization":{"fetchedAtMs":1700000000000,"utilization":{"five_hour":{"utilization":33},"seven_day":{"utilization":13}}}}"#
                .utf8
        ))!)
        assert(claude.percent == 33)
        assert(claude.detail.contains("5h 33%"))
        assert(claude.detail.contains("week 13%"))

        let grok = parseGrok(Data(
            #"{"config":{"creditUsagePercent":21,"currentPeriod":{"end":"2026-10-28T13:13:32.900673+00:00"},"productUsage":[{"product":"GrokBuild","usagePercent":17},{"product":"GrokChat","usagePercent":4}]}}"#
                .utf8
        ))
        assert(grok.percent == 21)
        assert(grok.detail.contains("Build 17%"))
        assert(grok.detail.contains("Chat 4%"))

        let cursor = parseCursor(Data(
            #"{"planUsage":{"totalPercentUsed":1.112},"displayMessage":"You've used 1% of your included usage"}"#
                .utf8
        ))
        assert(cursor.percent == 1.112)
        assert(cursor.detail.contains("included usage"))
        assert(parseCodex(Data("{}".utf8)).percent == nil)
    }
    #endif

    private static func readCodex() async -> QuotaReading {
        guard let file = jsonFile(".codex/auth.json") else {
            return .missing("Sign in with Codex")
        }
        let tokens = file["tokens"] as? [String: Any]
        let access = tokens?["access_token"] as? String
        guard let access, !access.isEmpty else {
            let apiKey = file["OPENAI_API_KEY"] as? String
            if file["auth_mode"] as? String == "apikey" || apiKey?.isEmpty == false {
                return .missing("Codex is using an API key, not a ChatGPT plan")
            }
            return .missing("Sign in with Codex")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = tokens?["account_id"] as? String, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        switch await send(request) {
        case .data(let data):
            return parseCodex(data)
        case .unauthorized:
            return .missing("Sign in to Codex again")
        case .failed:
            return .failed("Couldn't reach Codex")
        }
    }

    // Claude Code writes this file. Tally does not refresh Claude's token.
    private static func readClaude() -> QuotaReading {
        guard let file = jsonFile(".claude.json") else {
            return .missing("Sign in with Claude Code")
        }
        return parseClaude(file)
    }

    private static func readGrok() async -> QuotaReading {
        guard let token = grokToken() else {
            return .missing("Sign in with Grok")
        }
        if token.expires < Date() {
            return .missing("Open Grok to refresh the session")
        }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.timeoutInterval = 12
        let version = grokVersion()
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("grok-build", forHTTPHeaderField: "x-grok-client-surface")
        request.setValue("xai-grok-workspace/\(version)", forHTTPHeaderField: "User-Agent")
        switch await send(request) {
        case .data(let data):
            return parseGrok(data)
        case .unauthorized:
            return .missing("Sign in to Grok again")
        case .failed:
            return .failed("Couldn't reach Grok")
        }
    }

    private static func readCursor() async -> QuotaReading {
        guard let token = cursorAccessToken() else {
            return .missing("Sign in to Cursor")
        }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let user = cursorUserID(token) {
            request.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        }
        switch await send(request) {
        case .data(let data):
            return parseCursor(data)
        case .unauthorized:
            return .missing("Sign in to Cursor again")
        case .failed:
            return .failed("Couldn't reach Cursor")
        }
    }

    private static func parseCodex(_ data: Data) -> QuotaReading {
        guard let root = jsonObject(data),
              let rate = root["rate_limit"] as? [String: Any],
              let primary = rate["primary_window"] as? [String: Any],
              let used = jsonNumber(primary["used_percent"]) else {
            return .failed("Codex didn't return a usage window")
        }
        var bits: [String] = []
        if let plan = root["plan_type"] as? String, !plan.isEmpty {
            bits.append(plan.prefix(1).uppercased() + plan.dropFirst())
        }
        bits.append(windowName(jsonNumber(primary["limit_window_seconds"])))
        if let secondary = rate["secondary_window"] as? [String: Any],
           let week = jsonNumber(secondary["used_percent"]) {
            bits.append("week \(Int(week.rounded()))%")
        }
        if let reset = resets(parseDate(primary["reset_at"])) {
            bits.append(reset)
        }
        return .ready(used, bits.joined(separator: " · "))
    }

    private static func parseClaude(_ root: [String: Any]) -> QuotaReading {
        guard let cache = root["cachedUsageUtilization"] as? [String: Any],
              let util = cache["utilization"] as? [String: Any] else {
            return .missing("Sign in with Claude Code")
        }
        let session = jsonNumber((util["five_hour"] as? [String: Any])?["utilization"])
        let week = jsonNumber((util["seven_day"] as? [String: Any])?["utilization"])
        guard session != nil || week != nil else {
            return .missing("Sign in with Claude Code")
        }
        var bits: [String] = []
        if let session { bits.append("5h \(Int(session.rounded()))%") }
        if let week { bits.append("week \(Int(week.rounded()))%") }
        if let ms = jsonNumber(cache["fetchedAtMs"]) {
            bits.append("as of \(Format.clock(Date(timeIntervalSince1970: ms / 1000)))")
        }
        return .ready(max(session ?? 0, week ?? 0), bits.joined(separator: " · "))
    }

    private static func parseGrok(_ data: Data) -> QuotaReading {
        guard let root = jsonObject(data) else {
            return .failed("Couldn't read Grok usage")
        }
        let config = root["config"] as? [String: Any] ?? root
        guard let used = jsonNumber(config["creditUsagePercent"]) else {
            return .failed("Grok didn't return a usage window")
        }
        var bits = ["Week"]
        if let period = config["currentPeriod"] as? [String: Any], let reset = resets(parseDate(period["end"])) {
            bits.append(reset)
        }
        let products = (config["productUsage"] as? [Any] ?? []).compactMap { entry -> String? in
            guard let item = entry as? [String: Any],
                  let name = item["product"] as? String,
                  let percent = jsonNumber(item["usagePercent"]) else { return nil }
            return "\(productName(name)) \(Int(percent.rounded()))%"
        }
        if !products.isEmpty {
            bits.append(products.joined(separator: " · "))
        }
        return .ready(used, bits.joined(separator: " · "))
    }

    private static func parseCursor(_ data: Data) -> QuotaReading {
        guard let root = jsonObject(data) else {
            return .failed("Couldn't read Cursor usage")
        }
        let plan = (root["planUsage"] as? [String: Any])
            ?? ((root["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])
        guard let used = plan.flatMap({ jsonNumber($0["totalPercentUsed"]) }) else {
            if let message = root["displayMessage"] as? String, !message.isEmpty {
                return .failed(message)
            }
            return .failed("Cursor didn't return a usage window")
        }
        var bits: [String] = []
        if let message = root["displayMessage"] as? String, !message.isEmpty {
            bits.append(message)
        } else if let reset = resets(parseDate(root["billingCycleEnd"])) {
            bits.append(reset)
        }
        return .ready(used, bits.joined(separator: " · "))
    }

    private static func grokToken() -> (value: String, expires: Date)? {
        guard let file = jsonFile(".grok/auth.json") else { return nil }
        var best: (String, Date)?
        for value in file.values {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            let expires = parseDate(entry["expires_at"]) ?? .distantPast
            if best == nil || expires > best!.1 {
                best = (key, expires)
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func grokVersion() -> String {
        if let version = jsonFile(".grok/version.json")?["version"] as? String, !version.isEmpty {
            return version
        }
        // shortcut: billing host rejects old client versions, bump when requests come back outdated
        return "1.0.70"
    }

    private static func cursorAccessToken() -> String? {
        let path = home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func cursorUserID(_ token: String) -> String? {
        guard let sub = jwtClaim(token, "sub") else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    private static func jwtClaim(_ token: String, _ claim: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = jsonObject(data) else { return nil }
        return json[claim] as? String
    }

    private static func windowName(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Window" }
        let hours = seconds / 3600
        if abs(hours - 5) < 0.5 { return "5h" }
        if abs(hours - 24 * 7) < 6 { return "week" }
        if hours >= 24 * 27 && hours <= 24 * 32 { return "month" }
        if hours >= 48 { return "\(Int((hours / 24).rounded()))d" }
        return "\(max(Int(hours.rounded()), 1))h"
    }

    private static func productName(_ raw: String) -> String {
        switch raw {
        case "GrokBuild": "Build"
        case "GrokChat": "Chat"
        case "Api", "API": "API"
        default: raw.replacingOccurrences(of: "Grok", with: "")
        }
    }

    private static func resets(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "resets \(Format.dayMonth(date)) \(Format.clock(date))"
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = jsonNumber(value), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func jsonFile(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: home.appending(path: path)) else { return nil }
        return jsonObject(data)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private enum Fetch {
        case data(Data)
        case unauthorized
        case failed
    }

    private static func send(_ request: URLRequest) async -> Fetch {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 401 { return .unauthorized }
        guard (200..<300).contains(http.statusCode) else { return .failed }
        return .data(data)
    }
}
