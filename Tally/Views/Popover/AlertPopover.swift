import SwiftUI

struct AlertPopover: View {
    @Bindable var store: TallyStore
    var openHistory: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverTitle {
                GearButton(action: openSettings)
            }
            BudgetBanner(store: store)
            todayCard
            monthCard
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "TOP DRIVERS NOW")
                HStack {
                    Text(store.ledger.topDriver.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(store.money(store.ledger.topDriver.cost))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            HStack(spacing: 8) {
                Button("View cost drivers") {
                    store.detailTab = .conversations
                    store.conversationPeriod = .today
                    store.layout = .detailed
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Snooze today") {
                    store.snoozeToday()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.dailyLevel.color)
                }
                Text(store.money(store.ledger.todaySpend))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(store.dailyLevel.color)
                    .monospacedDigit()
                Text("of \(store.money(store.dailyBudget)) daily budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                BudgetBar(fraction: min(store.todayFraction, 1), tint: store.dailyLevel.color)
            }
        }
    }

    private var monthCard: some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "THIS MONTH")
                Text("\(store.money(store.ledger.monthSpend)) of \(store.moneyCompact(store.monthlyBudget))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                BudgetBar(fraction: store.monthFraction, tint: store.monthlyLevel == .ok ? .accentColor : store.monthlyLevel.color)
            }
        }
    }
}
