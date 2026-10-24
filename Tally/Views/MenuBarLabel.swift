import SwiftUI

struct MenuBarLabel: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let level = store.dailyLevel
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12))
            if store.menuBarStyle != .icon {
                Text(store.money(store.ledger.todaySpend))
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            if store.menuBarStyle == .meter {
                BudgetBar(fraction: store.todayFraction, tint: level.fill(scheme), height: 4)
                    .frame(width: 32)
            }
            if level == .warning {
                Circle()
                    .fill(level.fill(scheme))
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, level == .over ? 6 : 0)
        .padding(.vertical, level == .over ? 1 : 0)
        .background {
            if level == .over {
                Capsule().fill(Color.red.opacity(0.18))
            }
        }
        .fixedSize()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let amount = store.money(store.ledger.todaySpend)
        switch store.dailyLevel {
        case .ok: return "Tally \(amount)"
        case .warning: return "Tally \(amount), approaching daily budget"
        case .over: return "Tally \(amount), over daily budget"
        }
    }
}
