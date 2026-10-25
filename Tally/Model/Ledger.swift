import Foundation
import SwiftUI

enum AIModel: String, CaseIterable, Identifiable, Hashable {
    case claudeSonnet = "claude-sonnet"
    case gpt4o = "gpt-4o"
    case geminiPro = "gemini-pro"
    case gpt4oMini = "gpt-4o-mini"
    case claudeHaiku = "claude-haiku"

    var id: String { rawValue }

    var vendor: String {
        switch self {
        case .claudeSonnet, .claudeHaiku: "Anthropic"
        case .gpt4o, .gpt4oMini: "OpenAI"
        case .geminiPro: "Google"
        }
    }

    var qualifiedName: String {
        switch self {
        case .claudeSonnet: "anthropic/claude-sonnet"
        case .gpt4o: "openai/gpt-4o"
        case .geminiPro: "google/gemini-pro"
        case .gpt4oMini: "openai/gpt-4o-mini"
        case .claudeHaiku: "anthropic/claude-haiku"
        }
    }

    var color: Color {
        switch self {
        case .claudeSonnet: Color(red: 0.36, green: 0.42, blue: 0.96)
        case .gpt4o: Color(red: 0.000, green: 0.553, blue: 0.516)
        case .geminiPro: Color(red: 0.650, green: 0.457, blue: 0.000)
        case .gpt4oMini: Color(red: 0.000, green: 0.541, blue: 0.628)
        case .claudeHaiku: Color(red: 0.62, green: 0.36, blue: 0.95)
        }
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
        AIModel.allCases.compactMap { model in
            let matching = rows.filter { $0.model == model }
            guard !matching.isEmpty else { return nil }
            return ModelRow(
                model: model,
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

    static let shared = Ledger()

    static let conversations = [
        "CSR section 11 drafting",
        "Protocol synopsis review",
        "SLR abstract screening",
        "PSUR literature summary",
        "Label comparison EU/US",
        "Translation DE→EN",
        "Untagged",
    ]

    private init() {
        let snapshot = Ledger.date(24, 17, 44, 2)
        self.snapshot = snapshot
        todaySpend = 18.42
        monthSpend = 412.80
        projectedMonthEnd = 552
        projectionDate = Ledger.date(31, 0, 0, 0)
        todayRequestCount = 1_284
        todayTokensIn = 3_900_000
        todayTokensOut = 612_000
        topDriver = CostDriver(
            name: "CSR section 11 drafting",
            cost: 4.86,
            requests: 37,
            model: .claudeSonnet
        )
        monthModels = [
            ModelTotal(model: .claudeSonnet, requests: 1820, cost: 168.20),
            ModelTotal(model: .gpt4o, requests: 2410, cost: 121.50),
            ModelTotal(model: .geminiPro, requests: 960, cost: 64.30),
            ModelTotal(model: .gpt4oMini, requests: 5120, cost: 38.90),
            ModelTotal(model: .claudeHaiku, requests: 2200, cost: 19.90),
        ]
        todayModels = [
            ModelTotal(model: .claudeSonnet, requests: 566, cost: 8.12),
            ModelTotal(model: .gpt4o, requests: 372, cost: 5.34),
            ModelTotal(model: .geminiPro, requests: 216, cost: 3.10),
            ModelTotal(model: .gpt4oMini, requests: 84, cost: 1.20),
            ModelTotal(model: .claudeHaiku, requests: 46, cost: 0.66),
        ]
        monthConversations = [
            ConversationTotal(name: "CSR section 11 drafting", requests: 212, modelLabel: "claude-sonnet", cost: 38.40),
            ConversationTotal(name: "Protocol synopsis review", requests: 148, modelLabel: "gpt-4o", cost: 27.15),
            ConversationTotal(name: "SLR abstract screening", requests: 1040, modelLabel: "gpt-4o-mini", cost: 22.90),
            ConversationTotal(name: "PSUR literature summary", requests: 96, modelLabel: "claude-sonnet", cost: 18.62),
            ConversationTotal(name: "Label comparison EU/US", requests: 74, modelLabel: "gemini-pro", cost: 11.08),
            ConversationTotal(name: "Translation DE→EN", requests: 51, modelLabel: "gpt-4o", cost: 6.44),
            ConversationTotal(name: "Untagged requests", requests: 88, modelLabel: "mixed", cost: 4.20),
        ]
        dailySpend = [12, 15, 9, 22, 18, 14, 11, 19, 24, 16, 13, 21, 17, 18.42].enumerated().map { offset, amount in
            DailySpend(date: Ledger.date(11 + offset, 12, 0, 0), amount: amount)
        }

        let built = Ledger.pinnedRequests()
        requests = built.requests
        highlightedRequestID = built.highlight
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts) ?? Date()
    }

    private static func pinnedRequests() -> (requests: [UsageRequest], highlight: Int) {
        let drafts = pinnedRows().sorted { $0.time > $1.time }
        let requests = drafts.enumerated().map { index, draft in
            UsageRequest(
                id: index + 1,
                time: draft.time,
                model: draft.model,
                conversation: draft.conversation,
                input: draft.input,
                output: draft.output,
                cost: Double(draft.costMilli) / 10_000,
                status: draft.status
            )
        }
        let highlight = requests.first { $0.time == date(24, 17, 42, 40) }?.id ?? requests.first?.id ?? 1
        return (requests, highlight)
    }

    private struct Draft {
        var time: Date
        var model: AIModel
        var conversation: String
        var input: Int
        var output: Int
        var costMilli: Int
        var status: Int
    }

    private static func pinnedRows() -> [Draft] {
        func row(
            _ hour: Int, _ minute: Int, _ second: Int,
            _ model: AIModel, _ conversation: String,
            _ input: Int, _ output: Int, _ costMilli: Int, _ status: Int = 200
        ) -> Draft {
            Draft(
                time: date(24, hour, minute, second),
                model: model,
                conversation: conversation,
                input: input,
                output: output,
                costMilli: costMilli,
                status: status
            )
        }
        return [
            row(17, 44, 2, .claudeSonnet, "CSR section 11 drafting", 2412, 830, 197),
            row(17, 43, 51, .gpt4oMini, "SLR abstract screening", 1180, 96, 2),
            row(17, 43, 12, .gpt4o, "Protocol synopsis review", 3510, 1204, 208),
            row(17, 42, 40, .claudeSonnet, "CSR section 11 drafting", 8020, 1650, 488),
            row(17, 41, 5, .geminiPro, "Label comparison EU/US", 4100, 512, 77),
            row(17, 40, 33, .gpt4o, "—", 0, 0, 0, 429),
            row(17, 39, 58, .claudeHaiku, "Translation DE→EN", 900, 710, 11),
            row(17, 38, 20, .gpt4o, "Protocol synopsis review", 5880, 2010, 348),
            row(17, 36, 47, .claudeSonnet, "PSUR literature summary", 12400, 1980, 669),
            row(17, 35, 10, .gpt4oMini, "SLR abstract screening", 1204, 88, 2),
            row(17, 33, 2, .claudeSonnet, "CSR section 11 drafting", 6750, 1420, 416),
            row(17, 31, 44, .geminiPro, "Label comparison EU/US", 3300, 640, 73),
            row(17, 30, 15, .gpt4o, "Translation DE→EN", 1020, 880, 114),
            row(17, 28, 59, .claudeSonnet, "Untagged", 2200, 400, 126),
        ]
    }
}
