import SwiftUI

struct CompactPopover: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    var openHistory: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverTitle {
                HStack(spacing: 6) {
                    Text("Updated \(Format.clock(store.lastUpdated))")
                        .font(.caption)
                        .tallySecondary()
                    Button(action: store.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh")
                }
            }
            if let loadError = store.loadError {
                Text(loadError)
                    .font(.caption)
                    .tallySecondary()
                    .fixedSize(horizontal: false, vertical: true)
            } else if let loadNotice = store.loadNotice {
                Text(loadNotice)
                    .font(.caption)
                    .tallySecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.gatewayEnabled {
                todayCard
                monthCard
            }
            SubscriptionSection(store: store)
            if !store.gatewayEnabled && store.quotaSources.isEmpty {
                Text("Turn on a source in Settings to show it here.")
                    .font(.subheadline)
                    .tallySecondary()
            }

            if store.gatewayEnabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Top models today")
                    Spacer()
                    Button("See all") {
                        store.detailTab = .models
                        store.modelPeriod = .today
                        store.layout = .detailed
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .tallyAccent()
                }
                ForEach(Array(store.ledger.todayModels.prefix(3))) { total in
                    compactModel(total)
                }
            }
            }

            HStack(spacing: 8) {
                Button("Open Dashboard", action: openHistory)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Refresh", action: store.refresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
                GearButton(action: openSettings)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var todayCard: some View {
        PeriodSpendCard(
            title: "Today",
            amount: store.money(store.ledger.todaySpend),
            percent: Format.percent(store.todayFraction),
            level: store.dailyLevel,
            period: "daily",
            budgetLine: "of \(store.money(store.dailyBudget)) daily budget",
            fraction: store.todayFraction,
            tint: store.dailyLevel.fill(scheme)
        )
    }

    private var monthCard: some View {
        PeriodSpendCard(
            title: "This month",
            amount: store.money(store.ledger.monthSpend),
            percent: Format.percent(store.monthFraction),
            level: store.monthlyLevel,
            period: "monthly",
            budgetLine: "of \(store.money(store.monthlyBudget)) monthly budget",
            fraction: store.monthFraction,
            tint: store.monthlyLevel.fill(scheme),
            projection: "Projected \(store.moneyCompact(store.ledger.projectedMonthEnd)) by \(Format.dayMonth(store.ledger.projectionDate))"
        )
    }

    private func compactModel(_ total: ModelTotal) -> some View {
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

struct SubscriptionSection: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if !store.quotaSources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Subscriptions")
                ForEach(store.quotaSources) { source in
                    row(source)
                }
            }
        }
    }

    private func row(_ source: WidgetSource) -> some View {
        let reading = store.quotas[source]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(source.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(percentText(reading?.percent))
                    .font(.subheadline)
                    .monospacedDigit()
            }
            if let percent = reading?.percent {
                BudgetBar(
                    fraction: percent / 100,
                    tint: store.quotaLevel(percent).fill(scheme),
                    height: 4,
                    label: "percent of \(source.title) quota used"
                )
            }
            Text(reading?.detail ?? "Loading…")
                .font(.caption)
                .tallySecondary()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percentText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }
}
