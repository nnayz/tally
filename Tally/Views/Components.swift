import AppKit
import SwiftUI

enum TallyPalette {
    /// #757575 is 4.61:1 on white. Dark mode keeps system secondary (5.89:1 on #1E1E1E).
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.secondary : Color(white: 0.46)
    }

    /// Light #0066D6 is 5.42:1 on white. Dark #409CFF is 5.89:1 on #1E1E1E.
    static func accentText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.251, green: 0.612, blue: 1)
            : Color(red: 0, green: 0.400, blue: 0.839)
    }

    /// Light graphic #B45000. Dark keeps system orange so the light color is not reused.
    static func warningFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.orange : Color(red: 0.706, green: 0.314, blue: 0)
    }

    /// Light graphic #148232. Dark keeps system green.
    static func statusGreen(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.green : Color(red: 0.078, green: 0.510, blue: 0.196)
    }
}

private struct TallySecondary: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.foregroundStyle(TallyPalette.secondaryText(scheme))
    }
}

private struct TallyAccent: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.foregroundStyle(TallyPalette.accentText(scheme))
    }
}

extension View {
    func tallySecondary() -> some View { modifier(TallySecondary()) }
    func tallyAccent() -> some View { modifier(TallyAccent()) }
}

struct SpendCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PeriodSpendCard: View {
    var title: String
    var amount: String
    var percent: String
    var level: BudgetLevel
    var period: String
    var budgetLine: String
    var fraction: Double
    var tint: Color
    var projection: String? = nil

    var body: some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel(text: title)
                    Spacer()
                    Text(percent)
                        .font(.caption)
                        .monospacedDigit()
                        .tallySecondary()
                }
                Text(amount)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if level != .ok {
                    BudgetStatus(level: level, period: period)
                }
                Text(budgetLine)
                    .font(.subheadline)
                    .tallySecondary()
                BudgetBar(fraction: fraction, tint: tint)
                if let projection {
                    Text(projection)
                        .font(.caption)
                        .tallySecondary()
                }
            }
        }
    }
}

struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tallySecondary()
            .tracking(0.4)
            .textCase(.uppercase)
            .accessibilityLabel(text)
    }
}

struct BudgetBar: View {
    var fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6
    var label: String = "percent of budget"

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(tint)
                .frame(width: max(0, geo.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: height)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) \(label)")
    }
}

struct BudgetStatus: View {
    var level: BudgetLevel
    var period: String

    var body: some View {
        Label(level.statusTitle(period: period), systemImage: level.symbolName)
            .font(.caption2.weight(.semibold))
            .tallySecondary()
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

struct HeaderIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.primary.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct GearButton: View {
    var action: () -> Void

    var body: some View {
        HeaderIconButton(systemName: "gearshape", label: "Settings", action: action)
    }
}

/// A quiet badge for keys that report totals but cannot list requests.
struct MemberBadge: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text("Member")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TallyPalette.secondaryText(scheme))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .help("Totals for this key only. Request history needs an admin key.")
            .accessibilityLabel("Member key. Totals only. Request history needs an admin key.")
    }
}

/// The popover's tab row. A capsule selection keeps it in the same visual family as the period chips.
struct DetailTabBar: View {
    @Binding var selection: DetailTab
    var tabs: [DetailTab]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : TallyPalette.secondaryText(scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            selected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Only problems and truncation earn a line in the popover. Healthy capability detail lives in Settings.
struct PopoverNotice: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let message = store.loadError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(TallyPalette.warningFill(scheme))
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if store.loadFailure == GatewayClient.Failure.unapproved {
                    Button("Allow") {
                        Task { _ = await store.approveSpendHost() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .tallyAccent()
                    .help("Send the saved key to this spend host")
                } else {
                    Button("Retry", action: store.reloadSpend)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .tallyAccent()
                }
            }
        } else if let notice = store.loadNotice, !store.isMember, !notice.isEmpty {
            Text(notice)
                .font(.caption)
                .tallySecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PopoverTitle<Trailing: View>: View {
    var title: String = "Tally"
    @ViewBuilder var trailing: Trailing

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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let level = store.dailyLevel
        let tint: Color = level == .over ? .red : TallyPalette.warningFill(scheme)
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
                    .tallySecondary()
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
    @Binding var selection: DateRange
    var periods: [DateRange] = DateRange.chips

    var body: some View {
        HStack(spacing: 6) {
            ForEach(periods) { period in
                let selected = selection == period
                Button(period.chipTitle) { selection = period }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.primary)
                    .background {
                        Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                    .overlay {
                        Capsule().stroke(Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 1)
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}
