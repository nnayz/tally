import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class TallyStore {
    var ledger = Ledger(requests: [], now: Date(), dayStart: .utcMidnight)
    /// Set while the signed-in key is a member. Admin keys leave this nil and use request rows.
    private var memberSpend: GatewayClient.MemberSpend?
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

    /// Member keys report totals and cannot list requests.
    var isMember: Bool { memberSpend != nil }

    /// Tabs the current key can actually fill with data.
    var detailTabs: [DetailTab] {
        isMember ? [.overview, .models] : DetailTab.allCases
    }

    /// Member keys have no request rows, so cost drivers are models, not sessions.
    func showCostDrivers() {
        detailTab = isMember ? .models : .conversations
        if isMember {
            modelPeriod = .today
        } else {
            conversationPeriod = .today
        }
        layout = .detailed
    }

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
            ledger = currentLedger()
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
            noteManualEdit()
            persist()
            guard ready, !applyingProfile else { return }
            reloadSpend()
        }
    }
    var gatewayVersion: GatewayVersion {
        didSet {
            let previous = GatewayClient.presetSpendURL(gatewayURL, version: oldValue)
            if !applyingProfile, spendURLCustom.trimmingCharacters(in: .whitespacesAndNewlines) == previous {
                spendURLCustom = ""
            }
            noteManualEdit()
            persist()
            guard ready, !applyingProfile else { return }
            reloadSpend()
        }
    }
    var spendURLCustom: String {
        didSet {
            noteManualEdit()
            persist()
            guard ready, !applyingProfile else { return }
            reloadSpend()
        }
    }
    var keyPageURL: String {
        didSet {
            noteManualEdit()
            persist()
        }
    }
    var organization: String {
        didSet { persist() }
    }
    var profileScope: String {
        didSet { persist() }
    }
    var profilePermissions: [String] {
        didSet { persist() }
    }
    var helpURL: String {
        didSet { persist() }
    }
    var authorizationURL: String {
        didSet { persist() }
    }
    var tokenURL: String {
        didSet { persist() }
    }
    var revocationURL: String {
        didSet { persist() }
    }
    var clientID: String {
        didSet { persist() }
    }
    var trackingExpiry: TimeInterval {
        didSet { persist() }
    }
    var trackingTokenHost: String {
        didSet { persist() }
    }
    var authError: String?
    private var pendingChallenge: (verifier: String, state: String)?
    var profileWindow: String {
        didSet { persist() }
    }
    var profileFreshness: String {
        didSet { persist() }
    }
    var profileSource: String {
        didSet { persist() }
    }
    var profileHost: String {
        didSet { persist() }
    }
    var hostedProfileURL: String {
        didSet { persist() }
    }
    var setupLinkError: String?
    var profileError: String?
    var setupFailure: GatewayClient.Failure?
    var isLoadingSetup = false
    private var setupReportHost: String?
    private var setupGeneration = 0
    var approvedHostKey: String {
        didSet { persist() }
    }
    static let localProfileHost = "This Mac"
    private var applyingProfile = false
    private let defaultsStore: UserDefaults
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

    /// The preset path is already determined by the gateway and adapter. Show a field only for a different one.
    var showsCustomSpendURL: Bool {
        !spendURLCustom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var keyApproved: Bool {
        let key = GatewayClient.hostKey(of: spendURL)
        return !key.isEmpty && key == approvedHostKey
    }

    var displayedProfileHost: String {
        if setupFailure != nil, let setupReportHost, !setupReportHost.isEmpty {
            return setupReportHost
        }
        return profileHost.isEmpty ? Self.localProfileHost : profileHost
    }

    var spendHostLabel: String {
        let host = GatewayClient.reportHost(spendURL)
        return host == "unknown" ? "Not set" : host
    }

    var keyPageHostLabel: String {
        let page = keyPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.isEmpty { return "Not set" }
        let host = GatewayClient.reportHost(page)
        return host == "unknown" ? "Not set" : host
    }

    var scopeTitle: String {
        switch profileScope {
        case "this user": "This user"
        case "team": "Team"
        default: "This key"
        }
    }

    var showsExchange: Bool {
        !authorizationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tokenURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    init(defaults: UserDefaults = .standard, usesKeychain: Bool = true, performChecks: Bool = true) {
        defaultsStore = defaults
        let signedIn = defaults.object(forKey: Key.signedIn) as? Bool ?? false
        isSignedIn = signedIn
        launchAtLogin = SMAppService.mainApp.status == .enabled
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBar) ?? "") ?? .spend
        refreshSeconds = defaults.object(forKey: Key.refresh) as? Int ?? 60
        currencyCode = defaults.string(forKey: Key.currency) ?? "USD"
        let storedRate = defaults.object(forKey: Key.unitsPerUSD) as? Double ?? 1
        unitsPerUSD = storedRate > 0 ? storedRate : 1
        #if DEBUG
        if performChecks {
            Format.checkCurrencies()
            DayStart.checkBoundary()
        }
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
        gatewayURL = defaults.string(forKey: Key.gateway) ?? ""
        gatewayVersion = GatewayVersion(rawValue: defaults.string(forKey: Key.version) ?? "") ?? .v1_106_2
        spendURLCustom = defaults.string(forKey: Key.spendURL) ?? ""
        keyPageURL = defaults.string(forKey: Key.keyPage) ?? ""
        organization = defaults.string(forKey: Key.organization) ?? ""
        let storedScope = defaults.string(forKey: Key.profileScope) ?? "this key"
        profileScope = ["this key", "this user", "team"].contains(storedScope) ? storedScope : "this key"
        profilePermissions = defaults.stringArray(forKey: Key.profilePermissions) ?? ["Read spend logs"]
        helpURL = defaults.string(forKey: Key.helpURL) ?? ""
        authorizationURL = defaults.string(forKey: Key.authorizationURL) ?? ""
        tokenURL = defaults.string(forKey: Key.tokenURL) ?? ""
        revocationURL = defaults.string(forKey: Key.revocationURL) ?? ""
        clientID = defaults.string(forKey: Key.clientID) ?? ""
        trackingExpiry = defaults.object(forKey: Key.trackingExpiry) as? TimeInterval ?? 0
        trackingTokenHost = defaults.string(forKey: Key.trackingTokenHost) ?? ""
        profileWindow = defaults.string(forKey: Key.profileWindow) ?? ""
        profileFreshness = defaults.string(forKey: Key.profileFreshness) ?? ""
        profileSource = defaults.string(forKey: Key.profileSource) ?? "Entered on this Mac"
        profileHost = defaults.string(forKey: Key.profileHost) ?? Self.localProfileHost
        hostedProfileURL = defaults.string(forKey: Key.hostedProfileURL) ?? ""
        approvedHostKey = defaults.string(forKey: Key.approvedHost) ?? ""
        authMethod = AuthMethod(rawValue: defaults.string(forKey: Key.auth) ?? "") ?? .browser
        if usesKeychain {
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
        } else {
            apiKey = ""
        }
        announcedDaily = .ok
        announcedMonthly = .ok
        announcedDaily = dailyLevel
        announcedMonthly = monthlyLevel
        if apiKey.isEmpty {
            isSignedIn = false
        }
        #if DEBUG
        if performChecks {
            QuotaReader.selfCheck()
            GatewayClient.selfCheck()
        }
        #endif
        restartRefreshLoop()
        if !quotaSources.isEmpty {
            reloadQuotas()
        }
        ready = true
        dropPlaceholderGateway()
        #if DEBUG
        if performChecks {
            Self.checkSignedOutImport()
        }
        #endif
        reloadSpend()
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

    /// The key form is only the whole panel when no subscription is on.
    var showsConnectForm: Bool {
        gatewayEnabled && !isSignedIn && quotaSources.isEmpty
    }

    var phase: SessionPhase {
        if !isSignedIn { return .signedOut }
        let bare = ledger.requests.isEmpty && ledger.todaySpend == 0 && ledger.monthSpend == 0
        if bare && isLoadingUsage { return .loading }
        if bare && loadError != nil && memberSpend == nil { return .failed }
        if memberSpend != nil { return .live }
        if requests(on: Date()).isEmpty && ledger.todaySpend == 0 { return .empty }
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
        if let failure = GatewayClient.screenLink(page, label: "key page URL") {
            return failure.message
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    func beginTrackingSignIn() -> String? {
        authError = nil
        let authorization = authorizationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorization.isEmpty, !token.isEmpty, !client.isEmpty else {
            return "This gateway needs an operator integration."
        }
        if let failure = screenConfiguredLinks() {
            return failure.message
        }
        let made = TrackingAuth.makeChallenge()
        let state = TrackingAuth.randomState()
        guard let url = TrackingAuth.authorizeURL(
            endpoint: authorization,
            clientID: client,
            state: state,
            challenge: made.challenge
        ) else {
            return "This gateway needs an operator integration."
        }
        if !apiKey.isEmpty, url.absoluteString.contains(apiKey) {
            return "The sign-in request contained the API key and was not opened."
        }
        pendingChallenge = (verifier: made.verifier, state: state)
        NSWorkspace.shared.open(url)
        return nil
    }

    func completeTrackingSignIn(_ url: URL) async -> String? {
        guard url.scheme?.lowercased() == "tally", url.host?.lowercased() == "callback" else { return nil }
        guard let pending = pendingChallenge else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if query("error") != nil {
            pendingChallenge = nil
            return "The operator did not issue a tracking key."
        }
        guard query("state") == pending.state else {
            pendingChallenge = nil
            return "The sign-in response did not match this request. Start sign-in again."
        }
        guard let code = query("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            pendingChallenge = nil
            return "The sign-in response did not include a code."
        }
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let form = TrackingAuth.codeForm(clientID: client, code: code, verifier: pending.verifier)
        pendingChallenge = nil
        if !apiKey.isEmpty, form.contains(apiKey) || tokenURL.contains(apiKey) {
            return "The sign-in request contained the API key and was not sent."
        }
        let previousKey = apiKey
        let wasSignedIn = isSignedIn
        let previousApproved = approvedHostKey
        let previousRefresh = KeychainStore.string(account: "refreshToken")
        let previousExpiry = trackingExpiry
        let previousHost = trackingTokenHost
        let previousScope = profileScope
        switch await GatewayClient.redeem(tokenURL: tokenURL, form: form) {
        case .failure(let failure):
            return failure.message
        case .success(let credential):
            if let error = await signIn(apiKey: credential.accessToken) {
                if previousKey.isEmpty {
                    isSignedIn = false
                } else if KeychainStore.set(previousKey, account: "apiKey") {
                    apiKey = previousKey
                    approvedHostKey = previousApproved
                    isSignedIn = wasSignedIn
                }
                if let previousRefresh {
                    _ = KeychainStore.set(previousRefresh, account: "refreshToken")
                }
                trackingExpiry = previousExpiry
                trackingTokenHost = previousHost
                profileScope = previousScope
                return error
            }
            if let refresh = credential.refreshToken, !refresh.isEmpty {
                _ = KeychainStore.set(refresh, account: "refreshToken")
            }
            trackingExpiry = Date().timeIntervalSince1970 + credential.expiresIn
            trackingTokenHost = GatewayClient.hostKey(of: tokenURL)
            profileScope = credential.scope
            return nil
        }
    }

    func signIn(apiKey enteredKey: String) async -> String? {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an API key to continue." }
        if let failure = screenConfiguredLinks() {
            return failure.message
        }
        clearTrackingCredential()
        guard KeychainStore.set(trimmed, account: "apiKey") else {
            return "Couldn’t save the API key to the Keychain."
        }
        apiKey = trimmed
        authMethod = .apiKey
        approvedHostKey = GatewayClient.hostKey(of: spendURL)
        if let error = await loadGateway() {
            apiKey = ""
            approvedHostKey = ""
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
        let refresh = KeychainStore.string(account: "refreshToken") ?? ""
        let pin = trackingTokenHost
        let revocation = revocationURL
        pendingChallenge = nil
        authError = nil
        clearTrackingCredential()
        isSignedIn = false
        layout = .compact
        apiKey = ""
        loadError = nil
        loadFailure = nil
        loadNotice = nil
        memberSpend = nil
        lastUpdated = nil
        approvedHostKey = ""
        setupFailure = nil
        setupLinkError = nil
        setupReportHost = nil
        isLoadingSetup = false
        setupGeneration += 1
        isLoadingUsage = false
        loadGeneration += 1
        ledger = Ledger(requests: [], now: Date(), dayStart: dayStart)
        KeychainStore.remove(account: "session")
        KeychainStore.remove(account: "apiKey")
        if !refresh.isEmpty, GatewayClient.hostKey(of: revocation) == pin, !pin.isEmpty {
            Task {
                await GatewayClient.revoke(revocationURL: revocation, token: refresh, pinnedHost: pin)
            }
        }
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
        guard keyApproved else { return GatewayClient.Failure.unapproved.message }
        let previous = apiKey
        let previousRefresh = KeychainStore.string(account: "refreshToken")
        let previousExpiry = trackingExpiry
        let previousHost = trackingTokenHost
        clearTrackingCredential()
        guard KeychainStore.set(trimmed, account: "apiKey") else {
            if let previousRefresh {
                _ = KeychainStore.set(previousRefresh, account: "refreshToken")
            }
            trackingExpiry = previousExpiry
            trackingTokenHost = previousHost
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
            if let previousRefresh {
                _ = KeychainStore.set(previousRefresh, account: "refreshToken")
            }
            trackingExpiry = previousExpiry
            trackingTokenHost = previousHost
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

    private func currentLedger(requests: [UsageRequest]? = nil, now: Date = Date()) -> Ledger {
        if let memberSpend {
            return Ledger(member: memberSpend, now: now, dayStart: dayStart)
        }
        return Ledger(requests: requests ?? ledger.requests, now: now, dayStart: dayStart)
    }

    func reloadSpend() {
        guard gatewayEnabled, isSignedIn, !apiKey.isEmpty else { return }
        guard keyApproved else {
            loadError = GatewayClient.Failure.unapproved.message
            loadFailure = .unapproved
            loadNotice = nil
            return
        }
        Task { await loadGateway() }
    }

    @discardableResult
    func loadGateway() async -> String? {
        guard keyApproved else {
            loadError = GatewayClient.Failure.unapproved.message
            loadFailure = .unapproved
            loadNotice = nil
            return loadError
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingUsage = true
        if let message = await refreshTrackingIfNeeded() {
            guard generation == loadGeneration else { return nil }
            isLoadingUsage = false
            loadError = message
            loadFailure = GatewayClient.Failure(message: message, action: "Sign in again.")
            loadNotice = nil
            return message
        }
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
            memberSpend = read.member
            if read.member != nil {
                if !detailTabs.contains(detailTab) { detailTab = .overview }
                if !DateRange.memberChips.contains(modelPeriod) { modelPeriod = .thisMonth }
            }
            ledger = currentLedger(requests: read.requests)
            lastUpdated = Date()
            loadError = nil
            loadFailure = nil
            setupFailure = nil
            setupLinkError = nil
            setupReportHost = nil
            if read.role == .member {
                loadNotice = GatewayClient.memberNotice
            } else {
                loadNotice = read.truncated ? GatewayClient.truncationNotice : nil
            }
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
        report(failure: loadFailure, profileHost: profileHost)
    }

    func copyCapabilityReport() {
        let failure = setupFailure ?? loadFailure
        let host = setupFailure != nil ? (setupReportHost ?? profileHost) : profileHost
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(report(failure: failure, profileHost: host).text, forType: .string)
    }

    private func report(failure: GatewayClient.Failure?, profileHost host: String) -> CapabilityReport {
        let shown = host.isEmpty ? Self.localProfileHost : host
        var made = CapabilityReport.make(
            host: GatewayClient.reportHost(spendURL),
            profileHost: shown,
            declaredScope: scopeTitle,
            failure: failure,
            empty: lastUpdated != nil && ledger.requests.isEmpty && memberSpend == nil,
            checking: isLoadingUsage,
            synced: lastUpdated,
            now: Date()
        )
        if memberSpend != nil {
            made.history = "Request history needs an admin key."
            made.spend = "Available, this key only, member totals."
        }
        return made
    }

    private func blank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func screenConfiguredLinks() -> GatewayClient.Failure? {
        GatewayClient.screen(
            spendURL: spendURL,
            keyPageURL: keyPageURL,
            helpURL: helpURL,
            authorizationURL: authorizationURL,
            tokenURL: tokenURL,
            revocationURL: revocationURL
        )
    }

    private func clearTrackingCredential() {
        trackingExpiry = 0
        trackingTokenHost = ""
        KeychainStore.remove(account: "refreshToken")
    }

    /// An expired issued key is refreshed or dropped. A pasted key has no expiry and is left alone.
    private func refreshTrackingIfNeeded() async -> String? {
        guard TrackingAuth.isExpired(expiry: trackingExpiry, now: Date()) else { return nil }
        let refresh = KeychainStore.string(account: "refreshToken") ?? ""
        let tokenHost = GatewayClient.hostKey(of: tokenURL)
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty, !client.isEmpty, !tokenHost.isEmpty, tokenHost == trackingTokenHost else {
            return "This tracking key expired. Sign in again."
        }
        let form = TrackingAuth.refreshForm(clientID: client, refreshToken: refresh)
        if !apiKey.isEmpty, form.contains(apiKey) {
            return "This tracking key expired. Sign in again."
        }
        switch await GatewayClient.redeem(tokenURL: tokenURL, form: form) {
        case .failure:
            return "This tracking key expired. Sign in again."
        case .success(let credential):
            guard KeychainStore.set(credential.accessToken, account: "apiKey") else {
                return "Couldn’t save the API key to the Keychain."
            }
            apiKey = credential.accessToken
            if let next = credential.refreshToken, !next.isEmpty {
                _ = KeychainStore.set(next, account: "refreshToken")
            }
            trackingExpiry = Date().timeIntervalSince1970 + credential.expiresIn
            profileScope = credential.scope
            return nil
        }
    }

    func approveSpendHost() async -> String? {
        if let failure = screenConfiguredLinks() {
            loadError = failure.message
            loadFailure = failure
            loadNotice = nil
            return failure.message
        }
        approvedHostKey = GatewayClient.hostKey(of: spendURL)
        return await loadGateway()
    }

    func importProfile(from url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return "Couldn’t read the profile."
        }
        switch ConnectionProfile.decode(data) {
        case .failure(let failure):
            return failure.message
        case .success(let profile):
            if let failure = GatewayClient.screen(
                spendURL: profile.spendURL,
                keyPageURL: profile.keyPageURL,
                helpURL: profile.helpURL,
                authorizationURL: profile.authorizationURL ?? "",
                tokenURL: profile.tokenURL ?? "",
                revocationURL: profile.revocationURL ?? ""
            ) {
                return failure.message
            }
            apply(profile, source: url.lastPathComponent, profileHost: Self.localProfileHost)
            return nil
        }
    }

    func openSetupLink(_ url: URL) {
        setupGeneration += 1
        let generation = setupGeneration
        guard let profileURL = SetupLink.profileURL(from: url) else {
            isLoadingSetup = false
            noteSetupFailure(GatewayClient.Failure(
                message: "This setup link does not point at an https profile.",
                action: "Copy the setup link again from Tally."
            ), host: nil)
            return
        }
        let host = GatewayClient.reportHost(profileURL.absoluteString)
        isLoadingSetup = true
        setupLinkError = nil
        Task {
            let result = await GatewayClient.downloadProfile(from: profileURL.absoluteString)
            guard generation == setupGeneration else { return }
            isLoadingSetup = false
            switch result {
            case .failure(let failure):
                noteSetupFailure(failure, host: host)
            case .success(let profile):
                setupFailure = nil
                setupLinkError = nil
                setupReportHost = nil
                apply(profile, source: host, profileHost: host)
            }
        }
    }

    func copySetupLink() -> String? {
        switch SetupLink.make(hostedURL: hostedProfileURL) {
        case .failure(let failure):
            return failure.message
        case .success(let link):
            if !apiKey.isEmpty, link.contains(apiKey) {
                return "The setup link contained the API key and was not copied."
            }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(link, forType: .string)
            return nil
        }
    }

    private func noteSetupFailure(_ failure: GatewayClient.Failure, host: String?) {
        setupFailure = failure
        setupLinkError = failure.message
        setupReportHost = host
    }

    func exportProfile(to url: URL) -> String? {
        if let failure = screenConfiguredLinks() {
            return failure.message
        }
        switch makeProfile().encoded() {
        case .failure(let failure):
            return failure.message
        case .success(let data):
            if !apiKey.isEmpty, String(decoding: data, as: UTF8.self).contains(apiKey) {
                return "The profile contained the API key and was not written."
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return "Couldn’t write the profile."
            }
            return nil
        }
    }

    private func makeProfile() -> ConnectionProfile {
        let host = GatewayClient.reportHost(spendURL)
        let name = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = ["this key", "this user", "team"].contains(profileScope) ? profileScope : "this key"
        return ConnectionProfile(
            format: ConnectionProfile.formatVersion,
            organization: name.isEmpty ? host : name,
            adapter: gatewayVersion.rawValue,
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(url: spendURL, capability: "spend", credential: "apiKey"),
            ],
            keyPageURL: keyPageURL.trimmingCharacters(in: .whitespacesAndNewlines),
            permissions: profilePermissions.isEmpty ? ["Read spend logs"] : profilePermissions,
            helpURL: helpURL.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scope,
            window: profileWindow.isEmpty ? "Earlier of this month and 30 days ago" : profileWindow,
            freshness: profileFreshness.isEmpty ? "\(refreshSeconds) seconds" : profileFreshness,
            authorizationURL: blank(authorizationURL),
            tokenURL: blank(tokenURL),
            revocationURL: blank(revocationURL),
            clientID: blank(clientID)
        )
    }

    private func apply(_ profile: ConnectionProfile, source: String, profileHost host: String) {
        applyingProfile = true
        organization = profile.organization
        profileScope = profile.scope
        profilePermissions = profile.permissions
        helpURL = profile.helpURL
        authorizationURL = profile.authorizationURL ?? ""
        tokenURL = profile.tokenURL ?? ""
        revocationURL = profile.revocationURL ?? ""
        clientID = profile.clientID ?? ""
        profileWindow = profile.window
        profileFreshness = profile.freshness
        profileSource = source
        profileHost = host
        if let version = GatewayVersion(rawValue: profile.adapter) {
            gatewayVersion = version
        }
        let origin = GatewayClient.origin(of: profile.spendURL)
        if !origin.isEmpty { gatewayURL = origin }
        let preset = GatewayClient.presetSpendURL(gatewayURL, version: gatewayVersion)
        spendURLCustom = profile.spendURL == preset ? "" : profile.spendURL
        keyPageURL = profile.keyPageURL
        applyingProfile = false
        if isSignedIn, !apiKey.isEmpty, !keyApproved {
            loadError = GatewayClient.Failure.unapproved.message
            loadFailure = .unapproved
            loadNotice = nil
        } else {
            reloadSpend()
        }
    }

    /// example.com and gateway.example.com are documentation hosts, not a gateway this Mac connected.
    private func dropPlaceholderGateway() {
        guard !isSignedIn, apiKey.isEmpty else { return }
        let urls = [gatewayURL, spendURL, keyPageURL, helpURL, authorizationURL, tokenURL, revocationURL]
        let trimmed = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.contains(where: Self.isPlaceholderURL) else { return }
        guard trimmed.allSatisfy({ $0.isEmpty || Self.isPlaceholderURL($0) }) else { return }
        applyingProfile = true
        gatewayURL = ""
        spendURLCustom = ""
        keyPageURL = ""
        helpURL = ""
        authorizationURL = ""
        tokenURL = ""
        revocationURL = ""
        clientID = ""
        organization = ""
        profileWindow = ""
        profileFreshness = ""
        profileSource = "Entered on this Mac"
        profileHost = Self.localProfileHost
        applyingProfile = false
    }

    private static func isPlaceholderURL(_ raw: String) -> Bool {
        let host = GatewayClient.reportHost(raw)
        return host == "example.com" || host == "gateway.example.com"
    }

    private func noteManualEdit() {
        guard ready, !applyingProfile else { return }
        if profileSource != "Entered on this Mac" {
            profileSource = "Entered on this Mac"
        }
        if profileHost != Self.localProfileHost {
            profileHost = Self.localProfileHost
        }
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
        let defaults = defaultsStore
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
        defaults.set(organization, forKey: Key.organization)
        defaults.set(profileScope, forKey: Key.profileScope)
        defaults.set(profilePermissions, forKey: Key.profilePermissions)
        defaults.set(helpURL, forKey: Key.helpURL)
        defaults.set(authorizationURL, forKey: Key.authorizationURL)
        defaults.set(tokenURL, forKey: Key.tokenURL)
        defaults.set(revocationURL, forKey: Key.revocationURL)
        defaults.set(clientID, forKey: Key.clientID)
        defaults.set(trackingExpiry, forKey: Key.trackingExpiry)
        defaults.set(trackingTokenHost, forKey: Key.trackingTokenHost)
        defaults.set(profileWindow, forKey: Key.profileWindow)
        defaults.set(profileFreshness, forKey: Key.profileFreshness)
        defaults.set(profileSource, forKey: Key.profileSource)
        defaults.set(profileHost, forKey: Key.profileHost)
        defaults.set(hostedProfileURL, forKey: Key.hostedProfileURL)
        defaults.set(approvedHostKey, forKey: Key.approvedHost)
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
        static let organization = "organization"
        static let profileScope = "profileScope"
        static let profilePermissions = "profilePermissions"
        static let helpURL = "helpURL"
        static let authorizationURL = "authorizationURL"
        static let tokenURL = "tokenURL"
        static let revocationURL = "revocationURL"
        static let clientID = "clientID"
        static let trackingExpiry = "trackingExpiry"
        static let trackingTokenHost = "trackingTokenHost"
        static let profileWindow = "profileWindow"
        static let profileFreshness = "profileFreshness"
        static let profileSource = "profileSource"
        static let profileHost = "profileHost"
        static let hostedProfileURL = "hostedProfileURL"
        static let approvedHost = "approvedSpendHost"
        static let auth = "authMethod"
        static let sources = "enabledSources"
    }

    #if DEBUG
    /// Import must fill a signed-out Mac and must not store a key or sign in.
    private static func checkSignedOutImport() {
        let name = "com.nnayz.tally.signed-out-check"
        guard let defaults = UserDefaults(suiteName: name) else {
            assertionFailure("signed-out check defaults")
            return
        }
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let store = TallyStore(defaults: defaults, usesKeychain: false, performChecks: false)
        assert(!store.isSignedIn, "fresh store is signed out")
        assert(store.apiKey.isEmpty, "fresh store has no key")
        assert(store.gatewayURL.isEmpty, "fresh store has no gateway")
        assert(!store.showsCustomSpendURL, "preset spend is not its own field")
        assert(store.showsConnectForm, "gateway alone uses the key form")
        store.enabledSourceIDs = [WidgetSource.codex.rawValue]
        assert(!store.showsConnectForm, "a subscription is not the key form")
        store.enabledSourceIDs = [WidgetSource.gateway.rawValue]
        assert(store.showsConnectForm)

        let custom = ConnectionProfile(
            format: ConnectionProfile.formatVersion,
            organization: "Northwind",
            adapter: GatewayVersion.v1_49_6.rawValue,
            auth: "apiKey",
            endpoints: [
                ConnectionProfile.Endpoint(url: "https://llm.northwind.test/custom/logs", capability: "spend", credential: "apiKey"),
            ],
            keyPageURL: "https://llm.northwind.test/keys",
            permissions: ["Read spend logs"],
            helpURL: "https://llm.northwind.test/help",
            scope: "this key",
            window: "Earlier of this month and 30 days ago",
            freshness: "60 seconds"
        )
        store.apply(custom, source: "northwind.json", profileHost: Self.localProfileHost)
        assert(!store.isSignedIn, "import does not sign in")
        assert(store.apiKey.isEmpty, "import does not store a key")
        assert(store.organization == "Northwind")
        assert(store.gatewayURL == "https://llm.northwind.test")
        assert(store.gatewayVersion == .v1_49_6)
        assert(store.keyPageURL == "https://llm.northwind.test/keys")
        assert(store.spendURL == "https://llm.northwind.test/custom/logs")
        assert(store.showsCustomSpendURL, "a non-preset spend URL stays visible")
        assert(store.profileSource == "northwind.json")

        let presetURL = GatewayClient.presetSpendURL("https://llm.northwind.test", version: .v1_106_2)
        var preset = custom
        preset.adapter = GatewayVersion.v1_106_2.rawValue
        preset.endpoints = [
            ConnectionProfile.Endpoint(url: presetURL, capability: "spend", credential: "apiKey"),
        ]
        store.apply(preset, source: "northwind.json", profileHost: Self.localProfileHost)
        assert(store.gatewayVersion == .v1_106_2)
        assert(!store.showsCustomSpendURL, "the adapter’s own spend path is not a second field")
        assert(store.spendURL == presetURL)
        assert(!store.isSignedIn)
        assert(store.apiKey.isEmpty)

        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("tally-blocked-\(UUID().uuidString).json")
        let blockedJSON = #"{"format":1,"organization":"Loopback","adapter":"1.106.2","auth":"apiKey","endpoints":[{"url":"https://127.0.0.1/spend/logs/v2","capability":"spend","credential":"apiKey"}],"keyPageURL":"https://127.0.0.1/key","permissions":["Read spend logs"],"helpURL":"https://llm.northwind.test/help","scope":"this key","window":"Earlier of this month and 30 days ago","freshness":"60 seconds"}"#
        try? Data(blockedJSON.utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let blockedError = store.importProfile(from: blocked)
        assert(blockedError == GatewayClient.Failure.privateAddress.message, "private profile is refused while signed out")
        assert(store.organization == "Northwind", "a refused import leaves the previous profile")
        assert(!store.isSignedIn)
        assert(store.apiKey.isEmpty)

        let poisoned = FileManager.default.temporaryDirectory.appendingPathComponent("tally-secret-\(UUID().uuidString).json")
        try? Data(#"{"format":1,"apiKey":"sk-secret","adapter":"1.106.2"}"#.utf8).write(to: poisoned)
        defer { try? FileManager.default.removeItem(at: poisoned) }
        let secretError = store.importProfile(from: poisoned)
        assert(secretError == "This profile contains a secret. Remove it and share the file again.")
        assert(store.organization == "Northwind")
        assert(store.apiKey.isEmpty)
        assert(!store.isSignedIn)

        let missing = store.importProfile(from: FileManager.default.temporaryDirectory.appendingPathComponent("tally-missing-\(UUID().uuidString).json"))
        assert(missing == "Couldn’t read the profile.")
        assert(store.organization == "Northwind")
        assert(!store.isSignedIn)

        defaults.removePersistentDomain(forName: name)
        defaults.set("https://gateway.example.com", forKey: Key.gateway)
        defaults.set("Entered on this Mac", forKey: Key.profileSource)
        let factory = TallyStore(defaults: defaults, usesKeychain: false, performChecks: false)
        assert(factory.gatewayURL.isEmpty, "the factory example gateway is not a filled-in field")
        assert(!factory.isSignedIn)

        defaults.set("https://example.com", forKey: Key.gateway)
        defaults.set("https://example.com/spend/logs/v2", forKey: Key.spendURL)
        defaults.set("https://example.com/key", forKey: Key.keyPage)
        defaults.set("https://example.com/help", forKey: Key.helpURL)
        defaults.set("Example Gateway", forKey: Key.organization)
        defaults.set("tally-profile.sample.json", forKey: Key.profileSource)
        let sample = TallyStore(defaults: defaults, usesKeychain: false, performChecks: false)
        assert(sample.gatewayURL.isEmpty, "a sample example.com profile is not a connection")
        assert(sample.keyPageURL.isEmpty)
        assert(sample.organization.isEmpty)
        assert(sample.profileSource == "Entered on this Mac")
        assert(!sample.isSignedIn)
        assert(sample.apiKey.isEmpty)

        defaults.removePersistentDomain(forName: name)
        defaults.set("https://llm.example.com", forKey: Key.gateway)
        let kept = TallyStore(defaults: defaults, usesKeychain: false, performChecks: false)
        assert(kept.gatewayURL == "https://llm.example.com", "a real host is kept while signed out")
        kept.gatewayURL = "https://example.com"
        kept.apiKey = "sk-kept"
        kept.isSignedIn = true
        kept.dropPlaceholderGateway()
        assert(kept.gatewayURL == "https://example.com", "a signed-in key is not cleared")

        let roleName = name + ".role"
        let roleDefaults = UserDefaults(suiteName: roleName)!
        roleDefaults.removePersistentDomain(forName: roleName)
        let roleStore = TallyStore(defaults: roleDefaults, usesKeychain: false, performChecks: false)
        let member = GatewayClient.MemberSpend(today: 1, month: 2, todayModels: [], monthModels: [])
        roleStore.memberSpend = member
        roleStore.ledger = Ledger(member: member, now: Date(), dayStart: roleStore.dayStart)
        roleStore.isSignedIn = true
        assert(roleStore.phase == .live, "a member key with spend is connected")
        let quiet = GatewayClient.MemberSpend(today: 0, month: 0, todayModels: [], monthModels: [])
        roleStore.memberSpend = quiet
        roleStore.ledger = Ledger(member: quiet, now: Date(), dayStart: roleStore.dayStart)
        assert(roleStore.phase == .live, "a member key with zero spend still shows the totals")
        roleStore.memberSpend = nil
        roleStore.ledger = Ledger(requests: [], now: Date(), dayStart: roleStore.dayStart)
        assert(roleStore.phase == .empty, "an admin key with no requests today stays on the empty panel")
        roleDefaults.removePersistentDomain(forName: roleName)
    }
    #endif
}

enum SessionPhase {
    case signedOut
    case loading
    case failed
    case live
    case empty
}
