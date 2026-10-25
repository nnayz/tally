import Foundation
import SwiftUI

struct AIModel: Identifiable, Hashable {
    var id: String

    init(_ id: String) {
        self.id = id.isEmpty ? "unknown" : id
    }

    var rawValue: String { id }
    var qualifiedName: String { id }

    var vendor: String {
        let name = id.lowercased()
        if name.contains("claude") || name.contains("anthropic") { return "Anthropic" }
        if name.contains("gpt") || name.contains("openai") { return "OpenAI" }
        if name.contains("gemini") || name.contains("google") { return "Google" }
        if let slash = id.firstIndex(of: "/"), slash != id.startIndex {
            return String(id[..<slash])
        }
        return "Other"
    }

    var color: Color {
        let name = id.lowercased()
        if name.contains("haiku") { return Color(red: 0.62, green: 0.36, blue: 0.95) }
        if name.contains("claude") || name.contains("anthropic") { return Color(red: 0.36, green: 0.42, blue: 0.96) }
        if name.contains("mini") && (name.contains("gpt") || name.contains("openai")) {
            return Color(red: 0.000, green: 0.541, blue: 0.628)
        }
        if name.contains("gpt") || name.contains("openai") { return Color(red: 0.000, green: 0.553, blue: 0.516) }
        if name.contains("gemini") || name.contains("google") { return Color(red: 0.650, green: 0.457, blue: 0.000) }
        let palette = [
            Color(red: 0.36, green: 0.42, blue: 0.96),
            Color(red: 0.000, green: 0.553, blue: 0.516),
            Color(red: 0.650, green: 0.457, blue: 0.000),
            Color(red: 0.000, green: 0.541, blue: 0.628),
            Color(red: 0.62, green: 0.36, blue: 0.95),
        ]
        var hash = 0
        for byte in id.utf8 {
            hash = hash &* 31 &+ Int(byte)
        }
        let count = palette.count
        return palette[(hash % count + count) % count]
    }
}

enum BudgetLevel: Equatable {
    case ok
    case warning
    case over

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle"
        case .warning, .over: "exclamationmark.circle"
        }
    }

    func statusTitle(period: String) -> String {
        switch self {
        case .ok: "On track"
        case .warning: "Near \(period) limit"
        case .over: "Over \(period) limit"
        }
    }

    func fill(_ scheme: ColorScheme) -> Color {
        switch self {
        case .ok: Color.accentColor
        case .warning: TallyPalette.warningFill(scheme)
        case .over: Color.red
        }
    }
}

struct ModelTotal: Identifiable, Hashable {
    var model: AIModel
    var requests: Int
    var cost: Double

    var id: String { model.id }

    var perThousand: Double {
        requests == 0 ? 0 : cost / Double(requests) * 1000
    }
}

struct ConversationTotal: Identifiable, Hashable {
    var name: String
    var requests: Int
    var modelLabel: String
    var cost: Double

    var id: String { name }
}

enum UsageRollup {
    struct ModelRow: Identifiable {
        var model: AIModel
        var requests: Int
        var input: Int
        var output: Int
        var cost: Double
        var errors: Int
        var id: String { model.id }
    }

    struct ConversationRow: Identifiable {
        var name: String
        var requests: Int
        var input: Int
        var output: Int
        var cost: Double
        var models: Set<String>
        var id: String { name }
        var modelLabel: String { models.count == 1 ? (models.first ?? "mixed") : "mixed" }
    }

    static func models(in rows: [UsageRequest]) -> [ModelRow] {
        Dictionary(grouping: rows, by: \.model.id).map { _, matching in
            ModelRow(
                model: matching[0].model,
                requests: matching.count,
                input: matching.reduce(0) { $0 + $1.input },
                output: matching.reduce(0) { $0 + $1.output },
                cost: matching.reduce(0) { $0 + $1.cost },
                errors: matching.filter(\.isError).count
            )
        }
        .sorted { $0.cost > $1.cost }
    }

    static func conversations(in rows: [UsageRequest]) -> [ConversationRow] {
        let named = rows.filter { $0.conversation != "—" }
        return Set(named.map(\.conversation)).map { name in
            let matching = named.filter { $0.conversation == name }
            return ConversationRow(
                name: name,
                requests: matching.count,
                input: matching.reduce(0) { $0 + $1.input },
                output: matching.reduce(0) { $0 + $1.output },
                cost: matching.reduce(0) { $0 + $1.cost },
                models: Set(matching.map(\.model.rawValue))
            )
        }
        .sorted { $0.cost > $1.cost }
    }
}

struct DailySpend: Identifiable, Hashable {
    var date: Date
    var amount: Double
    var id: Date { date }
}

struct CostDriver: Hashable {
    var name: String
    var cost: Double
    var requests: Int
    var model: AIModel
}

struct UsageRequest: Identifiable, Hashable {
    var id: Int
    var time: Date
    var model: AIModel
    var conversation: String
    var input: Int
    var output: Int
    var cost: Double
    var status: Int

    var isError: Bool { status != 200 }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case spend
    case icon
    case meter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spend: "Today’s spend"
        case .icon: "Icon only"
        case .meter: "Cost + progress"
        }
    }
}

enum PopoverLayout: String {
    case compact
    case detailed
    case alert
}

enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case models
    case conversations
    case requests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .models: "Models"
        case .conversations: "Convos"
        case .requests: "Requests"
        }
    }
}

enum ModelSort: String, CaseIterable, Identifiable {
    case cost
    case requests
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .requests: "Requests"
        case .name: "Name"
        }
    }
}

enum HistoryView: String, CaseIterable, Identifiable {
    case allRequests
    case byModel
    case byConversation
    case errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allRequests: "All requests"
        case .byModel: "By model"
        case .byConversation: "By conversation"
        case .errors: "Errors"
        }
    }
}

enum DateRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7Days = "Last 7 days"
    case last30Days = "Last 30 days"
    case thisMonth = "This month"

    var id: String { rawValue }

    var chipTitle: String {
        switch self {
        case .today: "Today"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .thisMonth: "Month"
        }
    }

    static let chips: [DateRange] = [.today, .last7Days, .thisMonth]
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Success + errors"
    case success = "Success only"
    case errors = "Errors only"

    var id: String { rawValue }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum DayStart: String, CaseIterable, Identifiable {
    case utcMidnight
    case utcMorning
    case utcNoon
    case localMidnight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utcMidnight: "00:00 UTC"
        case .utcMorning: "06:00 UTC"
        case .utcNoon: "12:00 UTC"
        case .localMidnight: "Local midnight"
        }
    }

    /// Start of the billing day that contains `date`.
    func boundary(containing date: Date) -> Date {
        if self == .localMidnight {
            return Calendar.current.startOfDay(for: date)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let hour = switch self {
        case .utcMorning: 6
        case .utcNoon: 12
        default: 0
        }
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        guard var start = calendar.date(from: parts) else { return date }
        if date < start {
            start = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        }
        return start
    }

    func addingDays(_ count: Int, to date: Date) -> Date {
        if self == .localMidnight {
            return Calendar.current.date(byAdding: .day, value: count, to: date) ?? date
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(byAdding: .day, value: count, to: date) ?? date
    }

    #if DEBUG
    static func checkBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 5))!
        let before = DayStart.utcMorning.boundary(containing: early)
        let beforeParts = calendar.dateComponents([.day, .hour], from: before)
        assert(beforeParts.day == 23 && beforeParts.hour == 6)
        let onHour = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 6))!
        let onBoundary = DayStart.utcMorning.boundary(containing: onHour)
        let onParts = calendar.dateComponents([.day, .hour], from: onBoundary)
        assert(onParts.day == 24 && onParts.hour == 6)
    }
    #endif
}

enum AuthMethod: String, CaseIterable, Identifiable {
    case browser
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "Browser sign-in (SSO)"
        case .apiKey: "API key"
        }
    }
}

enum SettingsTab: String {
    case general
    case gateway
    case budgets
}

enum TallyWindow {
    static let history = "history"
}

struct Ledger {
    let snapshot: Date
    let todaySpend: Double
    let monthSpend: Double
    let projectedMonthEnd: Double
    let projectionDate: Date
    let todayRequestCount: Int
    let todayTokensIn: Int
    let todayTokensOut: Int
    let topDriver: CostDriver
    let monthModels: [ModelTotal]
    let todayModels: [ModelTotal]
    let monthConversations: [ConversationTotal]
    let dailySpend: [DailySpend]
    let requests: [UsageRequest]
    let highlightedRequestID: Int

    init(requests: [UsageRequest], now: Date, dayStart: DayStart) {
        snapshot = now
        let sorted = requests.sorted { $0.time > $1.time }.enumerated().map { index, request in
            var copy = request
            copy.id = index + 1
            return copy
        }
        self.requests = sorted
        highlightedRequestID = sorted.first?.id ?? 0

        let todayStart = dayStart.boundary(containing: now)
        let todayEnd = dayStart.addingDays(1, to: todayStart)
        let todayRows = sorted.filter { $0.time >= todayStart && $0.time < todayEnd }
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? todayStart
        let monthRows = sorted.filter { $0.time >= monthStart && $0.time <= now }

        todaySpend = todayRows.reduce(0) { $0 + $1.cost }
        monthSpend = monthRows.reduce(0) { $0 + $1.cost }
        todayRequestCount = todayRows.count
        todayTokensIn = todayRows.reduce(0) { $0 + $1.input }
        todayTokensOut = todayRows.reduce(0) { $0 + $1.output }
        todayModels = UsageRollup.models(in: todayRows).map {
            ModelTotal(model: $0.model, requests: $0.requests, cost: $0.cost)
        }
        monthModels = UsageRollup.models(in: monthRows).map {
            ModelTotal(model: $0.model, requests: $0.requests, cost: $0.cost)
        }
        monthConversations = UsageRollup.conversations(in: monthRows).map {
            ConversationTotal(name: $0.name, requests: $0.requests, modelLabel: $0.modelLabel, cost: $0.cost)
        }

        var days: [DailySpend] = []
        var cursor = calendar.startOfDay(for: monthStart)
        let lastDay = calendar.startOfDay(for: now)
        while cursor <= lastDay {
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            let amount = monthRows.filter { $0.time >= cursor && $0.time < next }.reduce(0) { $0 + $1.cost }
            days.append(DailySpend(date: cursor, amount: amount))
            cursor = next
        }
        dailySpend = days

        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let hoursLeft = max(nextMonth.timeIntervalSince(now) / 3600, 0)
        let elapsed = now.timeIntervalSince(todayStart)
        if todaySpend > 0, elapsed > 60 {
            projectedMonthEnd = monthSpend + todaySpend / (elapsed / 3600) * hoursLeft
        } else {
            projectedMonthEnd = monthSpend
        }
        let dayCount = calendar.range(of: .day, in: .month, for: now)?.count ?? 1
        var parts = calendar.dateComponents([.year, .month], from: now)
        parts.day = dayCount
        projectionDate = calendar.date(from: parts) ?? now

        let named = Dictionary(grouping: todayRows.filter { $0.conversation != "—" }, by: \.conversation)
        if let best = named.max(by: { Ledger.cost($0.value) < Ledger.cost($1.value) }) {
            let model = best.value.max { $0.cost < $1.cost }?.model ?? AIModel("unknown")
            topDriver = CostDriver(name: best.key, cost: Ledger.cost(best.value), requests: best.value.count, model: model)
        } else if let modelRow = todayModels.first {
            topDriver = CostDriver(name: modelRow.model.id, cost: modelRow.cost, requests: modelRow.requests, model: modelRow.model)
        } else {
            topDriver = CostDriver(name: "—", cost: 0, requests: 0, model: AIModel("unknown"))
        }
    }

    private static func cost(_ rows: [UsageRequest]) -> Double {
        rows.reduce(0) { $0 + $1.cost }
    }
}
