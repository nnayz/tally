import SwiftUI

struct MenuBarLabel: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let level = store.menuLevel
        HStack(spacing: 6) {
            if displayedSources.isEmpty {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12))
            }
            ForEach(displayedSources) { source in
                HStack(spacing: 2) {
                    SourceIcon(source: source)
                    if store.menuBarStyle != .icon {
                        Text(figure(source))
                            .font(.system(size: 13))
                            .monospacedDigit()
                    }
                }
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

    private var displayedSources: [WidgetSource] {
        var sources: [WidgetSource] = []
        if store.gatewayEnabled {
            sources.append(.gateway)
        }
        sources.append(contentsOf: store.quotaSources)
        return sources
    }

    private func figure(_ source: WidgetSource) -> String {
        switch source {
        case .gateway:
            return store.money(store.ledger.todaySpend)
        default:
            guard let percent = store.quotas[source]?.percent else { return "—" }
            return "\(Int(percent.rounded()))%"
        }
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
        if displayedSources == [.gateway] {
            let amount = store.money(store.ledger.todaySpend)
            switch store.dailyLevel {
            case .ok: return "Tally \(amount)"
            case .warning: return "Tally \(amount), approaching daily budget"
            case .over: return "Tally \(amount), over daily budget"
            }
        }
        if displayedSources.isEmpty { return "Tally" }
        let parts = displayedSources.map { source in
            "\(source.title) \(figure(source))"
        }
        return "Tally \(parts.joined(separator: ", "))"
    }
}

/// Menu-bar marks. Monochrome so they follow the bar’s light and dark tint.
private struct SourceIcon: View {
    var source: WidgetSource

    var body: some View {
        mark
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch source {
        case .gateway:
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 11))
        case .codex:
            OpenAIMark()
        case .claude:
            ClaudeMark()
        case .grok:
            GrokMark()
                .fill(style: FillStyle(eoFill: true))
        case .cursor:
            CursorMark()
        }
    }
}

/// Six blades, the OpenAI blossom, with the center cut out.
private struct OpenAIMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .frame(width: 3.2, height: 9)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
        .overlay {
            Circle()
                .frame(width: 2.6, height: 2.6)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// Anthropic starburst. Rays stay off the center so it doesn’t turn into a dot.
private struct ClaudeMark: View {
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .frame(width: 1.8, height: 4.4)
                    .offset(y: -3.4)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
        }
    }
}

/// Crescent, the small Grok mark.
private struct GrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: 0.4, dy: 0.4))
        let bite = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.22)
            .offsetBy(dx: rect.width * 0.28, dy: -rect.height * 0.2)
        path.addEllipse(in: bite)
        return path
    }
}

/// Pointer, for Cursor.
private struct CursorMark: Shape {
    func path(in rect: CGRect) -> Path {
        let minX = rect.minX
        let minY = rect.minY
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.08))
        path.addLine(to: CGPoint(x: minX + width * 0.16, y: minY + height * 0.86))
        path.addLine(to: CGPoint(x: minX + width * 0.40, y: minY + height * 0.66))
        path.addLine(to: CGPoint(x: minX + width * 0.54, y: minY + height * 0.92))
        path.addLine(to: CGPoint(x: minX + width * 0.70, y: minY + height * 0.82))
        path.addLine(to: CGPoint(x: minX + width * 0.54, y: minY + height * 0.56))
        path.addLine(to: CGPoint(x: minX + width * 0.86, y: minY + height * 0.56))
        path.closeSubpath()
        return path
    }
}
