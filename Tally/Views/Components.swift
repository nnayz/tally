import AppKit
import SwiftUI

struct SpendCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }
}

struct BudgetBar: View {
    var fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(tint)
                .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: height)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of budget")
    }
}

struct ModelDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

struct GearButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.primary.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

struct PopoverTitle: View {
    var title: String = "Tally"
    var trailing: AnyView

    init(title: String = "Tally", @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct BudgetBanner: View {
    @Bindable var store: TallyStore

    var body: some View {
        let level = store.dailyLevel
        let tint: Color = level == .over ? .red : .orange
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(level == .over ? "Daily budget exceeded" : "Approaching daily budget")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var message: String {
        if store.dailyLevel == .over {
            let over = max(store.ledger.todaySpend - store.dailyBudget, 0)
            return "\(store.money(store.ledger.todaySpend)) spent — \(store.money(over)) over the \(store.money(store.dailyBudget)) limit. Requests are not blocked."
        }
        let eta = store.limitEstimate().map { " around \($0)" } ?? ""
        return "\(store.money(store.ledger.todaySpend)) of \(store.money(store.dailyBudget)) used. At the current rate you reach the limit\(eta)."
    }
}

struct PeriodChips: View {
    @Binding var selection: SpendPeriod

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SpendPeriod.allCases) { period in
                let selected = selection == period
                Button(period.title) { selection = period }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .background {
                        Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                    .overlay {
                        Capsule().stroke(Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
        }
    }
}

enum AppWindows {
    static func activate() {
        NSApp.activate()
    }
}
