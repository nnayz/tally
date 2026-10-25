import Foundation
import SwiftUI

enum AIModel: String, CaseIterable, Identifiable, Hashable, Comparable {
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

    static func < (lhs: AIModel, rhs: AIModel) -> Bool {
        lhs.rawValue < rhs.rawValue
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

enum SpendPeriod: String, CaseIterable, Identifiable {
    case today
    case sevenDays
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .month: "Month"
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
    let cachedTodaySpend: Double
    let cachedMonthSpend: Double
    let cachedAt: Date
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
        cachedTodaySpend = 17.06
        cachedMonthSpend = 411.44
        cachedAt = Ledger.date(24, 16, 58, 0)
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

        let built = Ledger.makeRequests(snapshot: snapshot)
        requests = built.requests
        highlightedRequestID = built.highlight
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts) ?? Date()
    }

    private static func makeRequests(snapshot: Date) -> (requests: [UsageRequest], highlight: Int) {
        let pinned = pinnedRows()
        let todayFiller = synthesize(
            count: 1_270,
            errorCount: 7,
            costMilli: 184_200 - pinned.reduce(0) { $0 + $1.costMilli },
            input: 3_900_000 - pinned.reduce(0) { $0 + $1.input },
            output: 612_000 - pinned.reduce(0) { $0 + $1.output },
            start: date(24, 0, 5, 0),
            end: date(24, 17, 28, 0),
            seed: 24
        )
        let weekFiller = synthesize(
            count: 7_628,
            errorCount: 29,
            costMilli: 1_100_200,
            input: 23_500_000,
            output: 3_488_000,
            start: date(18, 0, 10, 0),
            end: date(23, 23, 50, 0),
            seed: 18
        )
        let monthFiller = synthesize(
            count: 6_400,
            errorCount: 44,
            costMilli: 2_843_600,
            input: 48_000_000,
            output: 7_200_000,
            start: date(1, 8, 0, 0),
            end: date(17, 22, 0, 0),
            seed: 1
        )

        let drafts = (pinned + todayFiller + weekFiller + monthFiller).sorted { $0.time > $1.time }
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
        let highlight = requests.first { $0.time == date(24, 17, 42, 40) }?.id ?? requests[0].id
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

    private static func synthesize(
        count: Int,
        errorCount: Int,
        costMilli: Int,
        input: Int,
        output: Int,
        start: Date,
        end: Date,
        seed: UInt64
    ) -> [Draft] {
        var rng = LCG(state: seed)
        var errorSlots = Set<Int>()
        while errorSlots.count < errorCount {
            errorSlots.insert(rng.int(count))
        }
        let span = end.timeIntervalSince(start)
        var weights: [Int] = []
        var drafts: [Draft] = []
        drafts.reserveCapacity(count)
        for index in 0..<count {
            let isError = errorSlots.contains(index)
            let weight = isError ? 0 : 40 + rng.int(160)
            weights.append(weight)
            drafts.append(Draft(
                time: start.addingTimeInterval(span * rng.unit()),
                model: pickModel(&rng),
                conversation: isError ? "—" : pickConversation(&rng),
                input: 0,
                output: 0,
                costMilli: 0,
                status: isError ? 429 : 200
            ))
        }
        let costs = distribute(total: costMilli, weights: weights)
        let inputs = distribute(total: input, weights: weights)
        let outputs = distribute(total: output, weights: weights)
        for index in drafts.indices {
            drafts[index].costMilli = costs[index]
            drafts[index].input = inputs[index]
            drafts[index].output = outputs[index]
        }
        return drafts
    }

    private static func distribute(total: Int, weights: [Int]) -> [Int] {
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0, total > 0 else { return Array(repeating: 0, count: weights.count) }
        var values = weights.map { total * $0 / weightSum }
        var remainder = total - values.reduce(0, +)
        var index = 0
        while remainder > 0 {
            if weights[index % weights.count] > 0 {
                values[index % values.count] += 1
                remainder -= 1
            }
            index += 1
        }
        return values
    }

    private static func pickModel(_ rng: inout LCG) -> AIModel {
        let roll = rng.int(100)
        switch roll {
        case 0..<34: return .claudeSonnet
        case 34..<62: return .gpt4o
        case 62..<76: return .geminiPro
        case 76..<92: return .gpt4oMini
        default: return .claudeHaiku
        }
    }

    private static func pickConversation(_ rng: inout LCG) -> String {
        let names = conversations
        let weights = [30, 18, 16, 10, 10, 8, 8]
        let roll = rng.int(weights.reduce(0, +))
        var cursor = 0
        for (name, weight) in zip(names, weights) {
            cursor += weight
            if roll < cursor { return name }
        }
        return names[0]
    }
}

private struct LCG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }

    mutating func int(_ upper: Int) -> Int {
        guard upper > 0 else { return 0 }
        return Int(next() % UInt64(upper))
    }

    mutating func unit() -> Double {
        Double(next() % 10_000) / 10_000
    }
}
