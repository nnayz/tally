import Charts
import SwiftUI

struct DetailedPopover: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    var openHistory: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PopoverTitle {
                HStack(spacing: 6) {
                    Circle()
                        .fill(TallyPalette.statusGreen(scheme))
                        .frame(width: 6, height: 6)
                    Text("Live · \(Format.clock(store.lastUpdated))")
                        .font(.caption)
                        .tallySecondary()
                    GearButton(action: openSettings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Picker("Section", selection: $store.detailTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                Button("Open Dashboard…", action: openHistory)
                    .buttonStyle(.plain)
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
        HStack(spacing: 8) {
            kpi("Today", amount: store.ledger.todaySpend, fraction: store.todayFraction, budget: store.dailyBudget, level: store.dailyLevel, period: "daily")
            kpi("This month", amount: store.ledger.monthSpend, fraction: store.monthFraction, budget: store.monthlyBudget, level: store.monthlyLevel, period: "monthly")
        }
        chartCard
        statsCard
        driverCard
    }

    private func kpi(_ title: String, amount: Double, fraction: Double, budget: Double, level: BudgetLevel, period: String) -> some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: title)
                Text(store.money(amount))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                BudgetStatus(level: level, period: period)
                BudgetBar(fraction: min(fraction, 1), tint: level.fill(scheme))
                Text("\(Format.percent(fraction)) of \(store.moneyCompact(budget))")
                    .font(.caption)
                    .monospacedDigit()
                    .tallySecondary()
            }
        }
    }

    private var chartCard: some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Daily spend · last 14 days")
                Chart {
                    ForEach(store.ledger.dailySpend) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Spend", day.amount)
                        )
                        .foregroundStyle(barColor(day))
                        .cornerRadius(2)
                    }
                    RuleMark(y: .value("Budget", store.dailyBudget))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Budget \(store.moneyCompact(store.dailyBudget))")
                                .font(.caption2)
                                .tallySecondary()
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
                Button("View conversation ›") {
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
        PeriodChips(selection: $store.modelPeriod)
        let totals = store.modelTotals(for: store.modelPeriod)
        let shares = store.sharePercents(totals)
        let sum = totals.reduce(0) { $0 + $1.cost }
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Spend by model · \(periodLabel)")
                stacked(totals, total: sum)
                Text("\(store.money(sum)) total · ^[\(totals.count) model](inflect: true)")
                    .font(.subheadline)
                Text("Stacked bar = share of \(store.modelPeriod == .month ? "monthly" : "period") spend")
                    .font(.caption)
                    .tallySecondary()
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
            Button("Compare models ›") {
                store.historyView = .byModel
                store.historyRange = store.modelPeriod == .today ? .today : (store.modelPeriod == .sevenDays ? .last7Days : .thisMonth)
                store.historyConversation = "All"
                store.historyModel = "All models"
                openHistory()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .tallyAccent()
        }
        SpendCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Model")
                    Text("Req")
                        .frame(width: 44, alignment: .trailing)
                        .accessibilityLabel("Req")
                    Text("$/1K req")
                        .frame(width: 58, alignment: .trailing)
                        .accessibilityLabel("$/1K req")
                    Text("Cost")
                        .frame(width: 72, alignment: .trailing)
                        .accessibilityLabel("Cost")
                }
                .font(.caption2)
                .tallySecondary()
                .textCase(.uppercase)
                .padding(.bottom, 6)
                ForEach(totals) { total in
                    Divider()
                    modelRow(total, share: shares[total.id] ?? 0)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var periodLabel: String {
        switch store.modelPeriod {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .month: store.ledger.snapshot.formatted(.dateTime.month(.abbreviated))
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

    private func modelRow(_ total: ModelTotal, share: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                ModelDot(color: total.model.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(total.model.rawValue)
                        .font(.subheadline.weight(.medium))
                    Text(total.model.vendor)
                        .font(.caption2)
                        .tallySecondary()
                    if let cap = store.cap(for: total.model), total.cost > cap {
                        Text("Over \(store.moneyCompact(cap)) cap")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.count(total.requests))
                .frame(width: 44, alignment: .trailing)
            Text(store.moneyCompact(total.perThousand))
                .frame(width: 58, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(store.money(total.cost))
                    .fontWeight(.semibold)
                Text("\(share)%")
                    .font(.caption2)
                    .monospacedDigit()
                    .tallySecondary()
            }
            .frame(width: 72, alignment: .trailing)
        }
        .font(.caption)
        .monospacedDigit()
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
                TextField("Conversations", text: $store.conversationQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search conversations")
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
                    Text("No conversations match.")
                        .font(.subheadline)
                        .tallySecondary()
                        .padding(.vertical, 12)
                }
                ForEach(rows) { row in
                    Button {
                        store.historyConversation = row.name == "Untagged requests" ? "Untagged" : row.name
                        store.historyRange = range
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
        case .sevenDays: period = "7 days"
        case .month: period = store.ledger.snapshot.formatted(.dateTime.month(.abbreviated))
        }
        return "Most expensive · \(period)"
    }

    private var range: DateRange {
        switch store.conversationPeriod {
        case .today: .today
        case .sevenDays: .last7Days
        case .month: .thisMonth
        }
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
                    label: "percent of the largest conversation"
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
                Button("View full history in window ›") {
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
                Text(Format.clock(row.time) + ":" + seconds(row.time))
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

    private func seconds(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ss"
        return formatter.string(from: date)
    }
}
