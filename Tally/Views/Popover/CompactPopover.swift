import SwiftUI

struct CompactPopover: View {
    @Bindable var store: TallyStore
    var openHistory: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverTitle {
                HStack(spacing: 6) {
                    Text("Updated \(Format.clock(store.lastUpdated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            todayCard
            monthCard

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "TOP MODELS TODAY")
                    Spacer()
                    Button("See all") {
                        store.detailTab = .models
                        store.modelPeriod = .today
                        store.layout = .detailed
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                ForEach(Array(store.ledger.todayModels.prefix(3))) { total in
                    compactModel(total)
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
        SpendCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: "TODAY")
                    Spacer()
                    Text(Format.percent(store.todayFraction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(store.money(store.ledger.todaySpend))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(store.dailyLevel.color)
                    .monospacedDigit()
                Text("of \(store.money(store.dailyBudget)) daily budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                BudgetBar(fraction: store.todayFraction, tint: barTint(store.dailyLevel))
            }
        }
    }

    private var monthCard: some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: "THIS MONTH")
                    Spacer()
                    Text(Format.percent(store.monthFraction))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(store.money(store.ledger.monthSpend))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(store.monthlyLevel.color)
                    .monospacedDigit()
                Text("of \(store.money(store.monthlyBudget)) monthly budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                BudgetBar(fraction: store.monthFraction, tint: barTint(store.monthlyLevel))
                Text("Projected \(store.moneyCompact(store.ledger.projectedMonthEnd)) by \(Format.dayMonth(store.ledger.projectionDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                height: 3
            )
            .padding(.leading, 16)
        }
    }

    private func barTint(_ level: BudgetLevel) -> Color {
        level == .ok ? .accentColor : level.color
    }
}
