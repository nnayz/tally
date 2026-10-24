import SwiftUI

struct SignInView: View {
    @Bindable var store: TallyStore
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tally")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 18)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .padding(.bottom, 16)

            Text("Connect your LLM Gateway")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to the gateway management portal to load usage and cost data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Gateway URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://gateway.example.com", text: $store.gatewayURL)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 18)

            if store.signInUsesAPIKey {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
                Button("Continue") {
                    store.signIn(apiKey: apiKey)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button("Sign in with Browser") {
                    store.signIn(apiKey: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                Button("Use API key instead") {
                    store.signInUsesAPIKey = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }

            Text("Credentials are stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tally")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            skeletonCard
            skeletonCard
            VStack(spacing: 10) {
                skeletonLine(width: 180)
                skeletonLine(width: 220)
                skeletonLine(width: 160)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Text("Fetching usage from gateway…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320, height: 360)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            skeletonLine(width: 70, height: 10)
            skeletonLine(width: 130, height: 22)
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func skeletonLine(width: CGFloat, height: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
    }
}

struct OfflineView: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tally")
                .font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can’t reach gateway")
                        .font(.subheadline.weight(.semibold))
                    Text("Showing cached data from \(Format.clock(store.ledger.cachedAt)). Retrying on the next refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Retry", action: store.refresh)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            cachedCard(title: "TODAY · CACHED", amount: store.ledger.cachedTodaySpend, budget: store.dailyBudget)
            cachedCard(title: "THIS MONTH · CACHED", amount: store.ledger.cachedMonthSpend, budget: store.monthlyBudget)

            Button("Session expired? Sign in again") {
                store.signOut()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func cachedCard(title: String, amount: Double, budget: Double) -> some View {
        SpendCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: title)
                Text(store.money(amount))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                BudgetBar(fraction: budget > 0 ? amount / budget : 0)
            }
        }
    }
}

struct EmptyUsageView: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Tally")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Spacer(minLength: 12)
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text("No requests yet today")
                .font(.headline)
            Text("Usage appears here once requests pass through the gateway. Monthly spend so far: \(store.money(store.ledger.monthSpend)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh", action: store.refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer(minLength: 12)
            Text("Budget: \(store.money(0)) of \(store.money(store.dailyBudget)) today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, height: 360)
    }
}
