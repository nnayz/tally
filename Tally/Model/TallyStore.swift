import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class TallyStore {
    var ledger = Ledger(requests: [], now: Date(), dayStart: .utcMidnight)
    var isLoadingUsage = false
    var loadError: String?
    var loadFailure: GatewayClient.Failure?
    var loadNotice: String?
    private var loadGeneration = 0
    private var seededLevels = false

    var isSignedIn: Bool {
        didSet { persist() }
    }
    var lastUpdated: Date?

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
        didSet {
            if currencyCode != oldValue {
                unitsPerUSD = 1
            }
            persist()
        }
    }
    // shortcut: one manual rate against USD, no live feed — add a rate source when display should track the market
    var unitsPerUSD: Double {
        didSet {
            if unitsPerUSD <= 0 { unitsPerUSD = 1 }
            persist()
        }
    }
    var dayStart: DayStart {
        didSet {
            persist()
            ledger = Ledger(requests: ledger.requests, now: Date(), dayStart: dayStart)
        }
    }
    var appearance: AppearanceChoice {
        didSet { persist() }
    }
    var dailyBudget: Double {
        didSet {
            persist()
            considerNotifications(previousDaily: oldValue == 0 ? dailyLevel : level(spent: ledger.todaySpend, budget: oldValue))
        }
    }
    var monthlyBudget: Double {
        didSet {
            persist()
            considerNotifications(previousMonthly: level(spent: ledger.monthSpend, budget: oldValue))
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
    var enabledSourceIDs: [String] {
        didSet {
            persist()
            reloadQuotas()
            reloadSpend()
        }
    }
    var quotas: [WidgetSource: QuotaReading] = [:]

    var gatewayURL: String {
        didSet {
            persist()
            guard ready else { return }
            reloadSpend()
        }
    }
    var gatewayVersion: GatewayVersion {
        didSet {
            let previous = GatewayClient.presetSpendURL(gatewayURL, version: oldValue)
            if spendURLCustom.trimmingCharacters(in: .whitespacesAndNewlines) == previous {
                spendURLCustom = ""
            }
            persist()
            guard ready else { return }
            reloadSpend()
        }
    }
    var spendURLCustom: String {
        didSet {
            persist()
            guard ready else { return }
            reloadSpend()
        }
    }
    var keyPageURL: String {
        didSet { persist() }
    }
    var authMethod: AuthMethod {
        didSet { persist() }
    }
    var apiKey: String

    private var ready = false

    var spendURL: String {
        let custom = spendURLCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return GatewayClient.presetSpendURL(gatewayURL, version: gatewayVersion)
    }

    var spendURLBinding: Binding<String> {
        Binding(
            get: { self.spendURL },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let preset = GatewayClient.presetSpendURL(self.gatewayURL, version: self.gatewayVersion)
                self.spendURLCustom = trimmed == preset ? "" : newValue
            }
        )
    }

    var layout: PopoverLayout = .compact
    var detailTab: DetailTab = .overview
    var modelPeriod: DateRange = .thisMonth
    var conversationPeriod: DateRange = .thisMonth
    var modelSort: ModelSort = .cost
    var conversationQuery = ""
    var settingsTab: SettingsTab = .general

    var historyView: HistoryView = .allRequests {
        didSet {
            if historyView == .errors {
                historyStatus = .errors
            }
        }
    }
    var historyRange: DateRange = .last7Days
    var historyModel: String = "All models"
    var historyConversation: String = "All"
    var historyStatus: StatusFilter = .all

    private var refreshTask: Task<Void, Never>?
    private var announcedDaily: BudgetLevel
    private var announcedMonthly: BudgetLevel

    init() {
        let defaults = UserDefaults.standard
        let signedIn = defaults.object(forKey: Key.signedIn) as? Bool ?? false
        isSignedIn = signedIn
        launchAtLogin = SMAppService.mainApp.status == .enabled
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBar) ?? "") ?? .spend
        refreshSeconds = defaults.object(forKey: Key.refresh) as? Int ?? 60
        currencyCode = defaults.string(forKey: Key.currency) ?? "USD"
        let storedRate = defaults.object(forKey: Key.unitsPerUSD) as? Double ?? 1
        unitsPerUSD = storedRate > 0 ? storedRate : 1
        #if DEBUG
        Format.checkCurrencies()
        DayStart.checkBoundary()
        #endif
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
        if let saved = defaults.stringArray(forKey: Key.sources) {
            enabledSourceIDs = saved
        } else {
            enabledSourceIDs = [WidgetSource.gateway.rawValue]
        }
        gatewayURL = defaults.string(forKey: Key.gateway) ?? "https://gateway.example.com"
        gatewayVersion = GatewayVersion(rawValue: defaults.string(forKey: Key.version) ?? "") ?? .v1_106_2
        spendURLCustom = defaults.string(forKey: Key.spendURL) ?? ""
        keyPageURL = defaults.string(forKey: Key.keyPage) ?? ""
        authMethod = AuthMethod(rawValue: defaults.string(forKey: Key.auth) ?? "") ?? .browser
        let storedKey = KeychainStore.string(account: "apiKey")
        if storedKey == "tally-sample-3f9a" {
            KeychainStore.remove(account: "apiKey")
            apiKey = ""
        } else {
            apiKey = storedKey ?? ""
        }
        if KeychainStore.string(account: "session") == "sample-session" {
            KeychainStore.remove(account: "session")
        }
        announcedDaily = .ok
        announcedMonthly = .ok
        announcedDaily = dailyLevel
        announcedMonthly = monthlyLevel
        if apiKey.isEmpty {
            isSignedIn = false
        }
        #if DEBUG
        QuotaReader.selfCheck()
        GatewayClient.selfCheck()
        #endif
        restartRefreshLoop()
        if !quotaSources.isEmpty {
            reloadQuotas()
        }
        ready = true
        if isSignedIn {
            isLoadingUsage = true
            Task { await loadGateway() }
        }
    }

    var gatewayEnabled: Bool { enabledSourceIDs.contains(WidgetSource.gateway.rawValue) }

    var quotaSources: [WidgetSource] {
        WidgetSource.allCases.filter { $0 != .gateway && enabledSourceIDs.contains($0.rawValue) }
    }

    func sourceBinding(_ source: WidgetSource) -> Binding<Bool> {
        Binding(
            get: { self.enabledSourceIDs.contains(source.rawValue) },
            set: { on in
                if on {
                    guard !self.enabledSourceIDs.contains(source.rawValue) else { return }
                    self.enabledSourceIDs.append(source.rawValue)
                } else {
                    self.enabledSourceIDs.removeAll { $0 == source.rawValue }
                }
            }
        )
    }

    func quotaLevel(_ percent: Double) -> BudgetLevel {
        level(spent: percent, budget: 100)
    }

    var menuLevel: BudgetLevel {
        var worst: BudgetLevel = gatewayEnabled ? dailyLevel : .ok
        for source in quotaSources {
            guard let percent = quotas[source]?.percent else { continue }
            worst = worse(worst, quotaLevel(percent))
        }
        return worst
    }

    var phase: SessionPhase {
        if !isSignedIn { return .signedOut }
        if ledger.requests.isEmpty && isLoadingUsage { return .loading }
        if ledger.requests.isEmpty && loadError != nil { return .failed }
        if requests(on: Date()).isEmpty { return .empty }
        return .live
    }

    var knownModels: [AIModel] {
        var models: [String: AIModel] = [:]
        for request in ledger.requests {
            models[request.model.id] = request.model
        }
        for key in modelCaps.keys where models[key] == nil {
            models[key] = AIModel(key)
        }
        return models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var knownConversations: [String] {
        Set(ledger.requests.map(\.conversation).filter { $0 != "—" }).sorted()
    }

    var todayFraction: Double { fraction(ledger.todaySpend, of: dailyBudget) }
    var monthFraction: Double { fraction(ledger.monthSpend, of: monthlyBudget) }
    var dailyLevel: BudgetLevel { level(spent: ledger.todaySpend, budget: dailyBudget) }
    var monthlyLevel: BudgetLevel { level(spent: ledger.monthSpend, budget: monthlyBudget) }

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    var shouldPresentAlert: Bool {
        gatewayEnabled && dailyLevel != .ok && !isSnoozed
    }

    var maskedAPIKey: String {
        guard apiKey.count >= 4 else { return "Not set" }
        return "••••••••••••\(apiKey.suffix(4))"
    }

    var displayRate: Double {
        Format.rate(code: currencyCode, unitsPerUSD: unitsPerUSD)
    }

    func displayAmount(_ usd: Double) -> Double {
        usd * displayRate
    }

    func usdAmount(_ shown: Double) -> Double {
        shown / displayRate
    }

    func money(_ value: Double, digits: Int = 2) -> String {
        Format.money(displayAmount(value), digits: digits, code: currencyCode)
    }

    func moneyCompact(_ value: Double) -> String {
        Format.moneyCompact(displayAmount(value), code: currencyCode)
    }

    func cap(for model: AIModel) -> Double? {
        guard let value = modelCaps[model.rawValue], value > 0 else { return nil }
        return value
    }

    func openKeyPage() -> String? {
        let page = keyPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: page), url.scheme == "https", url.host?.isEmpty == false else {
            return "Enter an https key page URL. A browser login does not connect Tally."
        }
        if GatewayClient.sameDestination(page, spendURL) {
            return "The spend URL and the key page must be different."
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    func signIn(apiKey enteredKey: String) async -> String? {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an API key to continue." }
        guard KeychainStore.set(trimmed, account: "apiKey") else {
            return "Couldn’t save the API key to the Keychain."
        }
        apiKey = trimmed
        authMethod = .apiKey
        if let error = await loadGateway() {
            apiKey = ""
            KeychainStore.remove(account: "apiKey")
            loadError = nil
            loadFailure = nil
            return error
        }
        isSignedIn = true
        layout = .compact
        detailTab = .overview
        return nil
    }

    func signOut() {
        isSignedIn = false
        layout = .compact
        apiKey = ""
        loadError = nil
        loadFailure = nil
        loadNotice = nil
        lastUpdated = nil
        isLoadingUsage = false
        loadGeneration += 1
        ledger = Ledger(requests: [], now: Date(), dayStart: dayStart)
        KeychainStore.remove(account: "session")
        KeychainStore.remove(account: "apiKey")
    }

    func snoozeToday() {
        snoozedUntil = nextReset()
        if layout == .alert {
            layout = .compact
        }
    }

    func replaceAPIKey(_ value: String) async -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an API key to continue." }
        let previous = apiKey
        guard KeychainStore.set(trimmed, account: "apiKey") else {
            return "Couldn’t save the API key to the Keychain."
        }
        apiKey = trimmed
        authMethod = .apiKey
        if let error = await loadGateway() {
            apiKey = previous
            if previous.isEmpty {
                KeychainStore.remove(account: "apiKey")
            } else {
                _ = KeychainStore.set(previous, account: "apiKey")
            }
            return error
        }
        isSignedIn = true
        return nil
    }

    func modelTotals(for period: DateRange) -> [ModelTotal] {
        let totals: [ModelTotal]
        switch period {
        case .today:
            totals = ledger.todayModels
        case .thisMonth:
            totals = ledger.monthModels
        case .last7Days, .last30Days:
            totals = UsageRollup.models(in: requests(in: period).filter { !$0.isError }).map {
                ModelTotal(model: $0.model, requests: $0.requests, cost: $0.cost)
            }
        }
        return sort(totals)
    }

    func conversationTotals(for period: DateRange) -> [ConversationTotal] {
        switch period {
        case .thisMonth:
            return ledger.monthConversations.filter { matchesConversation($0.name) }
        case .today:
            return conversationTotals(in: requests(on: Date()))
        case .last7Days, .last30Days:
            return conversationTotals(in: requests(in: period))
        }
    }

    func filteredRequests() -> [UsageRequest] {
        requests(in: historyRange).filter { request in
            if historyStatus == .errors, !request.isError { return false }
            if historyStatus == .success, request.isError { return false }
            if historyModel != "All models", request.model.rawValue != historyModel { return false }
            if historyConversation != "All", request.conversation != historyConversation { return false }
            return true
        }
    }

    func requests(in range: DateRange) -> [UsageRequest] {
        let start = rangeStart(range)
        let now = Date()
        return ledger.requests.filter { $0.time >= start && $0.time <= now }
    }

    func topModelToday() -> ModelTotal? {
        ledger.todayModels.max { $0.cost < $1.cost }
    }

    func limitEstimate() -> String? {
        let now = Date()
        let start = dayStart.boundary(containing: now)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 60, ledger.todaySpend > 0, ledger.todaySpend < dailyBudget else { return nil }
        let rate = ledger.todaySpend / elapsed
        let eta = now.addingTimeInterval((dailyBudget - ledger.todaySpend) / rate)
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

    private func conversationTotals(in rows: [UsageRequest]) -> [ConversationTotal] {
        UsageRollup.conversations(in: rows.filter { !$0.isError }).map {
            ConversationTotal(name: $0.name, requests: $0.requests, modelLabel: $0.modelLabel, cost: $0.cost)
        }
        .filter { matchesConversation($0.name) }
    }

    private func requests(on day: Date) -> [UsageRequest] {
        let start = dayStart.boundary(containing: day)
        let end = dayStart.addingDays(1, to: start)
        return ledger.requests.filter { $0.time >= start && $0.time < end }
    }

    private func rangeStart(_ range: DateRange) -> Date {
        let day = dayStart.boundary(containing: Date())
        switch range {
        case .today:
            return day
        case .last7Days:
            return dayStart.addingDays(-6, to: day)
        case .last30Days:
            return dayStart.addingDays(-29, to: day)
        case .thisMonth:
            let calendar = Calendar.current
            return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? day
        }
    }

    private func fraction(_ spent: Double, of budget: Double) -> Double {
        guard budget > 0 else { return 0 }
        return spent / budget
    }

    private func level(spent: Double, budget: Double, threshold: Double? = nil) -> BudgetLevel {
        let fraction = fraction(spent, of: budget)
        if fraction >= 1 { return .over }
        if fraction >= (threshold ?? warningThreshold) { return .warning }
        return .ok
    }

    private func considerNotifications(previousDaily: BudgetLevel? = nil, previousMonthly: BudgetLevel? = nil) {
        guard gatewayEnabled else { return }
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
        let percent = Int((fraction(spent, of: budget) * 100).rounded())
        let title: String
        let body: String
        if monthly {
            title = level == .over ? "Monthly budget exceeded" : "Monthly budget at \(percent)%"
            let days = daysLeftInMonth()
            body = "\(money(spent)) of \(money(budget)) · \(String(localized: "^[\(days) day](inflect: true)")) remaining"
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
        let now = Date()
        let day = calendar.component(.day, from: now)
        let range = calendar.range(of: .day, in: .month, for: now)
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

    private func worse(_ lhs: BudgetLevel, _ rhs: BudgetLevel) -> BudgetLevel {
        func rank(_ level: BudgetLevel) -> Int {
            switch level {
            case .ok: 0
            case .warning: 1
            case .over: 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private var quotaTask: Task<Void, Never>?

    func reloadQuotas() {
        let sources = quotaSources
        guard !sources.isEmpty else {
            quotas = [:]
            return
        }
        quotaTask?.cancel()
        quotaTask = Task { [weak self] in
            var fetched: [WidgetSource: QuotaReading] = [:]
            for source in sources {
                fetched[source] = await QuotaReader.read(source)
            }
            guard let self, !Task.isCancelled else { return }
            for source in sources {
                guard let reading = fetched[source] else { continue }
                if reading.percent == nil, !reading.unavailable, self.quotas[source]?.percent != nil {
                    continue
                }
                self.quotas[source] = reading
            }
            self.quotas = self.quotas.filter { sources.contains($0.key) }
        }
    }

    func refresh() {
        reloadQuotas()
        reloadSpend()
    }

    func reloadSpend() {
        guard gatewayEnabled, isSignedIn, !apiKey.isEmpty else { return }
        Task { await loadGateway() }
    }

    @discardableResult
    func loadGateway() async -> String? {
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingUsage = true
        let result = await GatewayClient.fetch(
            spendURL: spendURL,
            version: gatewayVersion,
            apiKey: apiKey,
            keyPageURL: keyPageURL
        )
        guard generation == loadGeneration else { return nil }
        isLoadingUsage = false
        switch result {
        case .success(let read):
            ledger = Ledger(requests: read.requests, now: Date(), dayStart: dayStart)
            lastUpdated = Date()
            loadError = nil
            loadFailure = nil
            loadNotice = read.truncated ? GatewayClient.truncationNotice : nil
            if seededLevels {
                considerNotifications()
            } else {
                announcedDaily = dailyLevel
                announcedMonthly = monthlyLevel
                seededLevels = true
            }
            return nil
        case .failure(let error):
            loadError = error.message
            loadFailure = error
            loadNotice = nil
            return error.message
        }
    }

    var capabilityReport: CapabilityReport {
        let now = Date()
        return CapabilityReport.make(
            host: GatewayClient.reportHost(spendURL),
            failure: loadFailure,
            empty: lastUpdated != nil && ledger.requests.isEmpty,
            checking: isLoadingUsage,
            synced: lastUpdated,
            now: now
        )
    }

    func copyCapabilityReport() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(capabilityReport.text, forType: .string)
    }

    func spendClock(stale: Bool, livePrefix: String = "Updated") -> String {
        guard let lastUpdated else { return "Not synchronized yet" }
        let clock = Format.clock(lastUpdated)
        if stale { return "Stale · \(clock)" }
        return "\(livePrefix) \(clock)"
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
        defaults.set(unitsPerUSD, forKey: Key.unitsPerUSD)
        defaults.set(dayStart.rawValue, forKey: Key.dayStart)
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(dailyBudget, forKey: Key.dailyBudget)
        defaults.set(monthlyBudget, forKey: Key.monthlyBudget)
        defaults.set(warningThreshold, forKey: Key.threshold)
        defaults.set(notifyWhenExceeded, forKey: Key.notifyOver)
        defaults.set(notifyAtWarning, forKey: Key.notifyWarning)
        defaults.set(snoozedUntil, forKey: Key.snooze)
        defaults.set(gatewayURL, forKey: Key.gateway)
        defaults.set(gatewayVersion.rawValue, forKey: Key.version)
        defaults.set(spendURLCustom, forKey: Key.spendURL)
        defaults.set(keyPageURL, forKey: Key.keyPage)
        defaults.set(authMethod.rawValue, forKey: Key.auth)
        defaults.set(enabledSourceIDs, forKey: Key.sources)
        if let data = try? JSONEncoder().encode(modelCaps) {
            defaults.set(data, forKey: Key.caps)
        }
    }

    private enum Key {
        static let signedIn = "signedIn"
        static let menuBar = "menuBarStyle"
        static let refresh = "refreshSeconds"
        static let currency = "currencyCode"
        static let unitsPerUSD = "unitsPerUSD"
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
        static let version = "gatewayVersion"
        static let spendURL = "spendURLCustom"
        static let keyPage = "keyPageURL"
        static let auth = "authMethod"
        static let sources = "enabledSources"
    }
}

enum SessionPhase {
    case signedOut
    case loading
    case failed
    case live
    case empty
}
