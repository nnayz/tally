import SwiftUI

struct MenuBarLabel: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let level = store.menuLevel
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 12))
            if store.menuBarStyle != .icon, !figureText.isEmpty {
                Text(figureText)
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            if store.menuBarStyle == .meter, let fraction = meterFraction {
                BudgetBar(fraction: fraction, tint: meterLevel.fill(scheme), height: 4)
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

    private var figureText: String {
        var parts: [String] = []
        if store.gatewayEnabled {
            parts.append(store.money(store.ledger.todaySpend))
        }
        for source in store.quotaSources {
            if let percent = store.quotas[source]?.percent {
                parts.append("\(source.menuLabel) \(Int(percent.rounded()))%")
            } else {
                parts.append(source.menuLabel)
            }
        }
        return parts.joined(separator: " · ")
    }

    private var meterFraction: Double? {
        if store.gatewayEnabled { return store.todayFraction }
        guard store.quotaSources.count == 1, let percent = store.quotas[store.quotaSources[0]]?.percent else {
            return nil
        }
        return percent / 100
    }

    /// The bar follows the figure it sits next to. The warning dot still uses every enabled source.
    private var meterLevel: BudgetLevel {
        store.gatewayEnabled ? store.dailyLevel : store.menuLevel
    }

    private var accessibilityText: String {
        if store.quotaSources.isEmpty && store.gatewayEnabled {
            let amount = store.money(store.ledger.todaySpend)
            switch store.dailyLevel {
            case .ok: return "Tally \(amount)"
            case .warning: return "Tally \(amount), approaching daily budget"
            case .over: return "Tally \(amount), over daily budget"
            }
        }
        if figureText.isEmpty { return "Tally" }
        return "Tally \(figureText)"
    }
}
