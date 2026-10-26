import Charts
import SwiftUI

struct DetailedPopover: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    var openHistory: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PopoverTitle {
                    HStack(spacing: 6) {
                        if store.loadError == nil {
                            Circle()
                                .fill(TallyPalette.statusGreen(scheme))
                                .frame(width: 6, height: 6)
                        }
                        Text(store.spendClock(stale: store.loadError != nil, livePrefix: "Live ·"))
                            .font(.caption)
                            .tallySecondary()
                        if store.isMember {
                            MemberBadge()
                        }
                        HeaderIconButton(systemName: "chevron.up", label: "Show less") {
                            store.layout = .compact
                        }
                        GearButton(action: openSettings)
                    }
                }
                PopoverNotice(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            DetailTabBar(selection: $store.detailTab, tabs: store.detailTabs)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch store.detailTab {
                    case .overview:
                        OverviewTab(store: store, openHistory: openHistory)
                    case .models:
                        ModelsTab(store: store, openHistory: openHistory)
                    case .conversations:
                        ConversationsTab(store: store, openHistory: openHistory)
                    case .requests:
                        RequestsTab(store: store, openHistory: openHistory)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                if !store.isMember {
                    Button("Open Usage History…", action: openHistory)
                        .buttonStyle(.plain)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .tallySecondary()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 360, height: 580)
        .onChange(of: store.isMember) { _, _ in
            if !store.detailTabs.contains(store.detailTab) {
                store.detailTab = .overview
            }
        }
    }
}

private struct OverviewTab: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    var openHistory: () -> Void

    var body: some View {
        if store.shouldPresentAlert {
            BudgetBanner(store: store)
        }
        SubscriptionSection(store: store)
        HStack(spacing: 8) {
            kpi("Today", amount: store.ledger.todaySpend, fraction: store.todayFraction, budget: store.dailyBudget, level: store.dailyLevel)
            kpi("This month", amount: store.ledger.monthSpend, fraction: store.monthFraction, budget: store.monthlyBudget, level: store.monthlyLevel)
        }
        if store.isMember {
            memberModelsCard
        } else {
            chartCard
            statsCard
            driverCard
        }
    }

    private func kpi(_ title: String, amount: Double, fraction: Double, budget: Double, level: BudgetLevel) -> some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: title)
                Text(store.money(amount))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                BudgetBar(fraction: min(fraction, 1), tint: level.fill(scheme))
                Text("\(Format.percent(fraction)) of \(store.moneyCompact(budget))")
                    .font(.caption)
                    .monospacedDigit()
                    .tallySecondary()
            }
        }
    }

    /// Member totals include model breakdowns, but no daily history or request rows.
    @ViewBuilder
    private var memberModelsCard: some View {
        let rows = Array(store.ledger.todayModels.prefix(4))
        if !rows.isEmpty {
            SpendCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Today by model")
                    ForEach(rows) { total in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                ModelDot(color: total.model.color)
                                Text(total.model.qualifiedName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(store.money(total.cost))
                                    .font(.subheadline)
                                    .monospacedDigit()
                            }
                            BudgetBar(
                                fraction: total.cost / max(store.ledger.todaySpend, 0.01),
                                tint: total.model.color,
                                height: 3,
                                label: "percent of today’s spend"
                            )
                            .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private var chartCard: some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Daily spend · this month")
                    Spacer()
                    Text("Budget \(store.moneyCompact(store.dailyBudget))")
                        .font(.caption2)
                        .monospacedDigit()
                        .tallySecondary()
                }
                Chart {
                    ForEach(store.ledger.dailySpend) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Spend", day.amount)
                        )
                        .foregroundStyle(barColor(day))
                        .cornerRadius(2)
                    }
                    if store.dailyBudget > 0 {
                        RuleMark(y: .value("Budget", store.dailyBudget))
                            .foregroundStyle(.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: [store.ledger.dailySpend.first?.date, store.ledger.dailySpend.last?.date].compactMap { $0 }) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                if Calendar.current.isDate(date, inSameDayAs: store.ledger.snapshot) {
                                    Text("Today")
                                } else {
                                    Text(Format.dayMonth(date))
                                }
                            }
                        }
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private func barColor(_ day: DailySpend) -> Color {
        Calendar.current.isDate(day.date, inSameDayAs: store.ledger.snapshot)
            ? Color.accentColor
            : Color.accentColor.opacity(0.35)
    }

    private var statsCard: some View {
        let count = store.ledger.todayRequestCount
        let average = count > 0 ? store.ledger.todaySpend / Double(count) : 0
        return SpendCard {
            HStack(alignment: .top) {
                stat("Requests", Format.count(count), "Today")
                stat("Tokens in", Format.tokens(store.ledger.todayTokensIn), nil)
                stat("Tokens out", Format.tokens(store.ledger.todayTokensOut), nil)
                stat("Avg / req", store.money(average, digits: 3), nil)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .tallySecondary()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .tallySecondary()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var driverCard: some View {
        let driver = store.ledger.topDriver
        return SpendCard {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Biggest cost driver today")
                Text(driver.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(store.money(driver.cost)) · ^[\(driver.requests) request](inflect: true) · \(driver.model.rawValue)")
                    .font(.caption)
                    .tallySecondary()
                Button("View session ›") {
                    store.historyConversation = driver.name
                    store.historyRange = .today
                    store.historyView = .allRequests
                    store.historyStatus = .all
                    openHistory()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .tallyAccent()
                .padding(.top, 2)
            }
        }
    }
}

private struct ModelsTab: View {
    @Bindable var store: TallyStore
    var openHistory: () -> Void

    var body: some View {
        PeriodChips(
            selection: $store.modelPeriod,
            periods: store.isMember ? DateRange.memberChips : DateRange.chips
        )
        let totals = store.modelTotals(for: store.modelPeriod)
        let shares = store.sharePercents(totals)
        let sum = totals.reduce(0) { $0 + $1.cost }
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Spend by model · \(periodLabel)")
                stacked(totals, total: sum)
                Text("\(store.money(sum)) total · ^[\(totals.count) model](inflect: true)")
                    .font(.subheadline)
            }
        }
        HStack {
            Menu {
                ForEach(ModelSort.allCases) { sort in
                    Button(sort.title) { store.modelSort = sort }
                }
            } label: {
                Text("Sort: \(store.modelSort.title)")
                    .font(.subheadline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if !store.isMember {
                Button("Compare models ›") {
                    store.historyView = .byModel
                    store.historyRange = store.modelPeriod
                    store.historyConversation = "All"
                    store.historyModel = "All models"
                    openHistory()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .tallyAccent()
            }
        }
        SpendCard {
            ModelsTable(store: store, totals: totals, shares: shares)
        }
    }

    private var periodLabel: String {
        switch store.modelPeriod {
        case .today: "Today"
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .thisMonth: store.ledger.snapshot.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func stacked(_ totals: [ModelTotal], total: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(totals.sorted { $0.cost > $1.cost }) { item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.model.color)
                        .frame(width: total > 0 ? max(4, geo.size.width * item.cost / total - 2) : 0)
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

}

/// One grid for the header and every model, so request, price, and cost share column edges.
private struct ModelsTable: View {
    @Bindable var store: TallyStore
    var totals: [ModelTotal]
    var shares: [String: Int]

    private enum Line: Identifiable {
        case rule(String)
        case model(ModelTotal)

        var id: String {
            switch self {
            case .rule(let key): "rule-\(key)"
            case .model(let total): total.id
            }
        }
    }

    private var lines: [Line] {
        var rows: [Line] = []
        for total in totals {
            if !rows.isEmpty {
                rows.append(.rule(total.id))
            }
            rows.append(.model(total))
        }
        return rows
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("Model")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Model")
                Text("Req")
                    .accessibilityLabel("Req")
                Text("$/1K req")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("$/1K req")
                Text("Cost")
                    .gridColumnAlignment(.trailing)
                    .accessibilityLabel("Cost")
            }
            .font(.caption2)
            .tallySecondary()
            .textCase(.uppercase)
            .padding(.bottom, 8)

            ForEach(lines) { line in
                switch line {
                case .rule:
                    GridRow {
                        Divider()
                            .gridCellColumns(4)
                            .padding(.vertical, 6)
                    }
                case .model(let total):
                    modelRow(total, share: shares[total.id] ?? 0)
                }
            }
        }
    }

    private func modelRow(_ total: ModelTotal, share: Int) -> some View {
        GridRow(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ModelDot(color: total.model.color)
                    Text(total.model.rawValue)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text(total.model.vendor)
                    .font(.caption2)
                    .tallySecondary()
                    .lineLimit(1)
                    .padding(.leading, 14)
                if let cap = store.cap(for: total.model), total.cost > cap {
                    Text("Over \(store.moneyCompact(cap)) cap")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.leading, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(total.requests, format: .number.grouping(.never))
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(store.moneyCompact(total.perThousand))
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .trailing, spacing: 2) {
                Text(store.money(total.cost))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text("\(share)%")
                    .font(.caption2)
                    .monospacedDigit()
                    .tallySecondary()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct ConversationsTab: View {
    @Bindable var store: TallyStore
    var openHistory: () -> Void

    var body: some View {
        PeriodChips(selection: $store.conversationPeriod)
        VStack(alignment: .leading, spacing: 4) {
            Text("Search")
                .font(.caption)
                .tallySecondary()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .tallySecondary()
                TextField("Sessions", text: $store.conversationQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search sessions")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }

        let rows = store.conversationTotals(for: store.conversationPeriod)
        let maxCost = rows.map(\.cost).max() ?? 1
        SpendCard {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: header)
                    .padding(.bottom, 8)
                if rows.isEmpty {
                    Text("No sessions match.")
                        .font(.subheadline)
                        .tallySecondary()
                        .padding(.vertical, 12)
                }
                ForEach(rows) { row in
                    Button {
                        store.historyConversation = row.name == "Untagged requests" ? "Untagged" : row.name
                        store.historyRange = store.conversationPeriod
                        store.historyView = .allRequests
                        store.historyStatus = .all
                        openHistory()
                    } label: {
                        conversationRow(row, maxCost: maxCost)
                    }
                    .buttonStyle(.plain)
                    if row.id != rows.last?.id {
                        Divider().padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private var header: String {
        let period: String
        switch store.conversationPeriod {
        case .today: period = "Today"
        case .last7Days: period = "7 days"
        case .last30Days: period = "30 days"
        case .thisMonth: period = store.ledger.snapshot.formatted(.dateTime.month(.abbreviated))
        }
        return "Most expensive · \(period)"
    }

    private func conversationRow(_ row: ConversationTotal, maxCost: Double) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.medium))
                Text("^[\(row.requests) request](inflect: true) · \(row.modelLabel)")
                    .font(.caption)
                    .tallySecondary()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(store.money(row.cost))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                BudgetBar(
                    fraction: maxCost > 0 ? row.cost / maxCost : 0,
                    height: 3,
                    label: "percent of the largest session"
                )
                .frame(width: 70)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .tallySecondary()
        }
        .contentShape(Rectangle())
    }
}

private struct RequestsTab: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    var openHistory: () -> Void

    var body: some View {
        let rows = Array(store.ledger.requests.prefix(50))
        SpendCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: "Recent requests")
                    Spacer()
                    Text("Last 50")
                        .font(.caption2)
                        .tallySecondary()
                }
                .padding(.bottom, 8)
                ForEach(rows) { row in
                    requestRow(row)
                    if row.id != rows.last?.id {
                        Divider().padding(.vertical, 6)
                    }
                }
                Button("Open Usage History ›") {
                    store.historyView = .allRequests
                    store.historyRange = .last7Days
                    store.historyConversation = "All"
                    store.historyModel = "All models"
                    store.historyStatus = .all
                    openHistory()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .tallyAccent()
                .padding(.top, 10)
            }
        }
    }

    private func requestRow(_ row: UsageRequest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ModelDot(color: row.isError ? .red : row.model.color, size: 6)
                Text(row.model.rawValue)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Format.clock(row.time, seconds: true))
                    .font(.caption)
                    .monospacedDigit()
                    .tallySecondary()
            }
            HStack {
                Text(row.isError ? "Error \(row.status) · not billed" : "\(row.conversation) · \(Format.count(row.input)) in / \(Format.count(row.output)) out")
                    .font(.caption)
                    .foregroundStyle(row.isError ? Color.primary : TallyPalette.secondaryText(scheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.cost == 0 ? store.money(0) : store.money(row.cost, digits: 4))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }
}
