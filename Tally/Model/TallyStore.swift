import Foundation
import Network
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class TallyStore {
    let ledger = Ledger.shared

    var isSignedIn: Bool {
        didSet { persist() }
    }
    var isLoading = false
    var isOffline = false
    var isRefreshing = false
    var lastUpdated: Date

    var launchAtLogin: Bool {
        didSet { persistLaunchAtLogin() }
    }
    private var isApplyingLaunch = false
    var menuBarStyle: MenuBarStyle {
        didSet { persist() }
    }
    var refreshSeconds: Int {
        didSet {
            persist()
            restartRefreshLoop()
        }
    }
    var currencyCode: String {
        didSet { persist() }
    }
    var dayStart: DayStart {
        didSet { persist() }
    }
    var appearance: AppearanceChoice {
        didSet { persist() }
    }
    var dailyBudget: Double {
        didSet {
            persist()
            considerNotifications(previousDaily: oldValue == 0 ? dailyLevel : level(for: ledger.todaySpend, budget: oldValue))
        }
    }
    var monthlyBudget: Double {
        didSet {
            persist()
            considerNotifications(previousMonthly: level(for: ledger.monthSpend, budget: oldValue))
        }
    }
    var warningThreshold: Double {
        didSet {
            persist()
            considerNotifications(
                previousDaily: level(spent: ledger.todaySpend, budget: dailyBudget, threshold: oldValue),
                previousMonthly: level(spent: ledger.monthSpend, budget: monthlyBudget, threshold: oldValue)
            )
        }
    }
    var notifyWhenExceeded: Bool {
        didSet { persist() }
    }
    var notifyAtWarning: Bool {
        didSet { persist() }
    }
    var snoozedUntil: Date? {
        didSet { persist() }
    }
    var modelCaps: [String: Double] {
        didSet { persist() }
    }

    var gatewayURL: String {
        didSet { persist() }
    }
    var authMethod: AuthMethod {
        didSet { persist() }
    }
    var accountEmail: String
    var teamName: String
    var tokenExpires: Date
    var apiKey: String

    var layout: PopoverLayout = .compact
    var detailTab: DetailTab = .overview
    var modelPeriod: SpendPeriod = .month
    var conversationPeriod: SpendPeriod = .month
    var modelSort: ModelSort = .cost
    var conversationQuery = ""
    var settingsTab: SettingsTab = .general
    var signInUsesAPIKey = false

    var historyView: HistoryView = .allRequests
    var historyRange: DateRange = .last7Days
    var historyModel: String = "All models"
    var historyConversation: String = "All"
    var historyStatus: StatusFilter = .all

    private var refreshTask: Task<Void, Never>?
    private var announcedDaily: BudgetLevel
    private var announcedMonthly: BudgetLevel
    private var didPromptForNotifications = false

    init() {
        let defaults = UserDefaults.standard
        let signedIn = defaults.object(forKey: Key.signedIn) as? Bool ?? true
        isSignedIn = signedIn
        lastUpdated = Ledger.shared.snapshot
        launchAtLogin = SMAppService.mainApp.status == .enabled
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBar) ?? "") ?? .spend
        refreshSeconds = defaults.object(forKey: Key.refresh) as? Int ?? 60
        currencyCode = defaults.string(forKey: Key.currency) ?? "USD"
        dayStart = DayStart(rawValue: defaults.string(forKey: Key.dayStart) ?? "") ?? .utcMidnight
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        dailyBudget = defaults.object(forKey: Key.dailyBudget) as? Double ?? 25
        monthlyBudget = defaults.object(forKey: Key.monthlyBudget) as? Double ?? 600
        warningThreshold = defaults.object(forKey: Key.threshold) as? Double ?? 0.8
        notifyWhenExceeded = defaults.object(forKey: Key.notifyOver) as? Bool ?? true
        notifyAtWarning = defaults.object(forKey: Key.notifyWarning) as? Bool ?? true
        if let snooze = defaults.object(forKey: Key.snooze) as? Date {
            snoozedUntil = snooze
        }
        if let data = defaults.data(forKey: Key.caps),
           let caps = try? JSONDecoder().decode([String: Double].self, from: data) {
            modelCaps = caps
        } else {
            modelCaps = [:]
        }
        gatewayURL = defaults.string(forKey: Key.gateway) ?? "https://gateway.example.com"
        authMethod = AuthMethod(rawValue: defaults.string(forKey: Key.auth) ?? "") ?? .browser
        accountEmail = "jane.doe@example.com"
        teamName = "Medical Writing"
        tokenExpires = Ledger.shared.snapshot.addingTimeInterval(6 * 86_400)
        let storedKey = KeychainStore.string(account: "apiKey") ?? "tally-sample-3f9a"
        apiKey = storedKey
        announcedDaily = .ok
        announcedMonthly = .ok
        if signedIn && KeychainStore.string(account: "apiKey") == nil {
            KeychainStore.set(storedKey, account: "apiKey")
            KeychainStore.set("sample-session", account: "session")
        }
        announcedDaily = dailyLevel
        announcedMonthly = monthlyLevel
        restartRefreshLoop()
    }

    var phase: SessionPhase {
        if isLoading { return .loading }
        if !isSignedIn { return .signedOut }
        if isOffline { return .offline }
        if requests(on: ledger.snapshot).isEmpty { return .empty }
        return .live
    }

    var todayFraction: Double { fraction(ledger.todaySpend, of: dailyBudget) }
    var monthFraction: Double { fraction(ledger.monthSpend, of: monthlyBudget) }
    var dailyLevel: BudgetLevel { level(for: ledger.todaySpend, budget: dailyBudget) }
    var monthlyLevel: BudgetLevel { level(for: ledger.monthSpend, ofBudget: monthlyBudget) }

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    var shouldPresentAlert: Bool {
        dailyLevel != .ok && !isSnoozed
    }

    var maskedAPIKey: String {
        let suffix = apiKey.suffix(4)
        return "••••••••••••\(suffix)"
    }

    func money(_ value: Double, digits: Int = 2) -> String {
        Format.money(value, digits: digits, code: currencyCode)
    }

    func moneyCompact(_ value: Double) -> String {
        Format.moneyCompact(value, code: currencyCode)
    }

    func cap(for model: AIModel) -> Double? {
        guard let value = modelCaps[model.rawValue], value > 0 else { return nil }
        return value
    }

    func refresh() {
        guard isSignedIn, !isLoading else { return }
        isRefreshing = true
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "tally.reachability")
        monitor.pathUpdateHandler = { [weak self] path in
            monitor.cancel()
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                self.lastUpdated = Date()
                self.isOffline = !online
            }
        }
        monitor.start(queue: queue)
    }

    func signIn(apiKey enteredKey: String?) {
        isLoading = true
        isOffline = false
        if let enteredKey, !enteredKey.isEmpty {
            authMethod = .apiKey
            apiKey = enteredKey
            KeychainStore.set(enteredKey, account: "apiKey")
        } else {
            authMethod = .browser
            if KeychainStore.string(account: "apiKey") == nil {
                KeychainStore.set(apiKey, account: "apiKey")
            }
        }
        KeychainStore.set("sample-session", account: "session")
        accountEmail = "jane.doe@example.com"
        teamName = "Medical Writing"
        tokenExpires = Date().addingTimeInterval(6 * 86_400)
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            isLoading = false
            isSignedIn = true
            layout = .compact
            detailTab = .overview
        }
    }

    func signOut() {
        isSignedIn = false
        isOffline = false
        isLoading = false
        layout = .compact
        KeychainStore.remove(account: "session")
        KeychainStore.remove(account: "apiKey")
    }

    func snoozeToday() {
        snoozedUntil = nextReset()
        if layout == .alert {
            layout = .compact
        }
    }

    func replaceAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apiKey = trimmed
        KeychainStore.set(trimmed, account: "apiKey")
    }

    func modelTotals(for period: SpendPeriod) -> [ModelTotal] {
        let totals: [ModelTotal]
        switch period {
        case .today:
            totals = ledger.todayModels
        case .month:
            totals = ledger.monthModels
        case .sevenDays:
            totals = aggregateModels(requests(in: .last7Days))
        }
        return sort(totals)
    }

    func conversationTotals(for period: SpendPeriod) -> [ConversationTotal] {
        switch period {
        case .month:
            return ledger.monthConversations.filter { matchesConversation($0.name) }
        case .today:
            return aggregateConversations(requests(on: ledger.snapshot)).filter { matchesConversation($0.name) }
        case .sevenDays:
            return aggregateConversations(requests(in: .last7Days)).filter { matchesConversation($0.name) }
        }
    }

    func filteredRequests() -> [UsageRequest] {
        requests(in: historyRange).filter { request in
            if historyView == .errors || historyStatus == .errors, !request.isError { return false }
            if historyStatus == .success, request.isError { return false }
            if historyModel != "All models", request.model.rawValue != historyModel { return false }
            if historyConversation != "All", request.conversation != historyConversation { return false }
            return true
        }
    }

    func requests(in range: DateRange) -> [UsageRequest] {
        let start = rangeStart(range)
        return ledger.requests.filter { $0.time >= start && $0.time <= ledger.snapshot }
    }

    func topModelToday() -> ModelTotal? {
        ledger.todayModels.max { $0.cost < $1.cost }
    }

    func limitEstimate() -> String? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: ledger.snapshot)
        let elapsed = ledger.snapshot.timeIntervalSince(start)
        guard elapsed > 60, ledger.todaySpend > 0, ledger.todaySpend < dailyBudget else { return nil }
        let rate = ledger.todaySpend / elapsed
        let eta = ledger.snapshot.addingTimeInterval((dailyBudget - ledger.todaySpend) / rate)
        return Format.clock(eta)
    }

    func sharePercents(_ totals: [ModelTotal]) -> [String: Int] {
        let sum = totals.reduce(0) { $0 + $1.cost }
        guard sum > 0 else { return [:] }
        var raw = totals.map { ($0.id, Int(($0.cost / sum * 100).rounded())) }
        let drift = raw.reduce(0) { $0 + $1.1 } - 100
        if drift != 0, let index = raw.indices.max(by: { raw[$0].1 < raw[$1].1 }) {
            raw[index].1 -= drift
        }
        return Dictionary(uniqueKeysWithValues: raw)
    }

    private func matchesConversation(_ name: String) -> Bool {
        let query = conversationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query)
    }

    private func sort(_ totals: [ModelTotal]) -> [ModelTotal] {
        switch modelSort {
        case .cost:
            totals.sorted { $0.cost > $1.cost }
        case .requests:
            totals.sorted { $0.requests > $1.requests }
        case .name:
            totals.sorted { $0.model.rawValue < $1.model.rawValue }
        }
    }

    private func aggregateModels(_ rows: [UsageRequest]) -> [ModelTotal] {
        AIModel.allCases.compactMap { model in
            let matching = rows.filter { $0.model == model && !$0.isError }
            let cost = matching.reduce(0) { $0 + $1.cost }
            guard !matching.isEmpty else { return nil }
            return ModelTotal(model: model, requests: matching.count, cost: cost)
        }
    }

    private func aggregateConversations(_ rows: [UsageRequest]) -> [ConversationTotal] {
        let names = Set(rows.map(\.conversation)).filter { $0 != "—" }
        return names.map { name in
            let matching = rows.filter { $0.conversation == name && !$0.isError }
            let models = Set(matching.map(\.model.rawValue))
            let label = models.count == 1 ? (models.first ?? "mixed") : "mixed"
            return ConversationTotal(
                name: name,
                requests: matching.count,
                modelLabel: label,
                cost: matching.reduce(0) { $0 + $1.cost }
            )
        }
        .sorted { $0.cost > $1.cost }
    }

    private func requests(on day: Date) -> [UsageRequest] {
        let calendar = Calendar.current
        return ledger.requests.filter { calendar.isDate($0.time, inSameDayAs: day) }
    }

    private func rangeStart(_ range: DateRange) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: ledger.snapshot)
        switch range {
        case .today:
            return day
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: day) ?? day
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: day) ?? day
        case .thisMonth:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: ledger.snapshot)) ?? day
        }
    }

    private func fraction(_ spent: Double, of budget: Double) -> Double {
        guard budget > 0 else { return 0 }
        return spent / budget
    }

    private func level(for spent: Double, budget: Double, threshold: Double? = nil) -> BudgetLevel {
        level(spent: spent, budget: budget, threshold: threshold ?? warningThreshold)
    }

    private func level(for spent: Double, ofBudget budget: Double) -> BudgetLevel {
        level(spent: spent, budget: budget, threshold: warningThreshold)
    }

    private func level(spent: Double, budget: Double, threshold: Double) -> BudgetLevel {
        let fraction = fraction(spent, of: budget)
        if fraction >= 1 { return .over }
        if fraction >= threshold { return .warning }
        return .ok
    }

    private func considerNotifications(previousDaily: BudgetLevel? = nil, previousMonthly: BudgetLevel? = nil) {
        let dailyBefore = previousDaily ?? announcedDaily
        let monthlyBefore = previousMonthly ?? announcedMonthly
        if dailyLevel != dailyBefore {
            announce(level: dailyLevel, spent: ledger.todaySpend, budget: dailyBudget, monthly: false)
            announcedDaily = dailyLevel
        }
        if monthlyLevel != monthlyBefore {
            announce(level: monthlyLevel, spent: ledger.monthSpend, budget: monthlyBudget, monthly: true)
            announcedMonthly = monthlyLevel
        }
    }

    private func announce(level: BudgetLevel, spent: Double, budget: Double, monthly: Bool) {
        guard !isSnoozed else { return }
        switch level {
        case .ok:
            return
        case .warning:
            guard notifyAtWarning else { return }
        case .over:
            guard notifyWhenExceeded else { return }
        }
        if !didPromptForNotifications {
            didPromptForNotifications = true
            BudgetNotifications.requestAuthorization()
        }
        let percent = Int((fraction(spent, of: budget) * 100).rounded())
        let title: String
        let body: String
        if monthly {
            title = level == .over ? "Monthly budget exceeded" : "Monthly budget at \(percent)%"
            let days = daysLeftInMonth()
            body = "\(money(spent)) of \(money(budget)) · \(days) days remaining"
        } else if level == .over {
            title = "Daily budget exceeded"
            body = "\(money(spent)) of \(money(budget)) · tap to see cost drivers"
        } else {
            title = "\(percent)% of daily budget used"
            let driver = topModelToday()
            let share = driver.map { Int(($0.cost / max(ledger.todaySpend, 0.01) * 100).rounded()) } ?? 0
            let name = driver?.model.rawValue ?? "the top model"
            body = "\(money(spent)) of \(money(budget)) · \(name) is \(share)% of today"
        }
        BudgetNotifications.post(title: title, body: body)
    }

    private func daysLeftInMonth() -> Int {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: ledger.snapshot)
        let range = calendar.range(of: .day, in: .month, for: ledger.snapshot)
        return max((range?.count ?? day) - day, 0)
    }

    private func nextReset() -> Date {
        let now = Date()
        switch dayStart {
        case .localMidnight:
            return Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86_400)
        case .utcMidnight, .utcMorning, .utcNoon:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let hour = dayStart == .utcMorning ? 6 : (dayStart == .utcNoon ? 12 : 0)
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86_400)
        }
    }

    private func restartRefreshLoop() {
        refreshTask?.cancel()
        let seconds = refreshSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func persistLaunchAtLogin() {
        guard !isApplyingLaunch else { return }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            isApplyingLaunch = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isApplyingLaunch = false
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(isSignedIn, forKey: Key.signedIn)
        defaults.set(menuBarStyle.rawValue, forKey: Key.menuBar)
        defaults.set(refreshSeconds, forKey: Key.refresh)
        defaults.set(currencyCode, forKey: Key.currency)
        defaults.set(dayStart.rawValue, forKey: Key.dayStart)
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(dailyBudget, forKey: Key.dailyBudget)
        defaults.set(monthlyBudget, forKey: Key.monthlyBudget)
        defaults.set(warningThreshold, forKey: Key.threshold)
        defaults.set(notifyWhenExceeded, forKey: Key.notifyOver)
        defaults.set(notifyAtWarning, forKey: Key.notifyWarning)
        defaults.set(snoozedUntil, forKey: Key.snooze)
        defaults.set(gatewayURL, forKey: Key.gateway)
        defaults.set(authMethod.rawValue, forKey: Key.auth)
        if let data = try? JSONEncoder().encode(modelCaps) {
            defaults.set(data, forKey: Key.caps)
        }
    }

    private enum Key {
        static let signedIn = "signedIn"
        static let menuBar = "menuBarStyle"
        static let refresh = "refreshSeconds"
        static let currency = "currencyCode"
        static let dayStart = "dayStart"
        static let appearance = "appearance"
        static let dailyBudget = "dailyBudget"
        static let monthlyBudget = "monthlyBudget"
        static let threshold = "warningThreshold"
        static let notifyOver = "notifyWhenExceeded"
        static let notifyWarning = "notifyAtWarning"
        static let snooze = "snoozedUntil"
        static let caps = "modelCaps"
        static let gateway = "gatewayURL"
        static let auth = "authMethod"
    }
}

enum SessionPhase {
    case signedOut
    case loading
    case live
    case offline
    case empty
}
