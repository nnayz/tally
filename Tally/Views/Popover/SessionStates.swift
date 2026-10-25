import AppKit
import SwiftUI

struct SignInView: View {
    @Bindable var store: TallyStore
    @State private var apiKey = ""
    @State private var apiKeyError: String?
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        ScrollView {
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
            Text("Open the key page, copy your virtual key, and paste it here.")
                .font(.subheadline)
                .tallySecondary()
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("Gateway URL")
                    .font(.caption)
                    .tallySecondary()
                TextField("https://gateway.example.com", text: $store.gatewayURL)
                    .textFieldStyle(.roundedBorder)
                Text("LiteLLM")
                    .font(.caption)
                    .tallySecondary()
                Picker("LiteLLM", selection: $store.gatewayVersion) {
                    ForEach(GatewayVersion.allCases) { version in
                        Text(version.title).tag(version)
                    }
                }
                .labelsHidden()
                Text("Spend URL")
                    .font(.caption)
                    .tallySecondary()
                TextField("https://gateway.example.com/spend/logs/v2", text: store.spendURLBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Key page URL")
                    .font(.caption)
                    .tallySecondary()
                TextField("https://gateway.example.com/key", text: $store.keyPageURL)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.caption)
                    .tallySecondary()
                SecureField("", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API key")
                    .focused($apiKeyFocused)
                if let apiKeyError {
                    Text(apiKeyError)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            Button(store.isLoadingUsage ? "Checking…" : "Continue") {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    apiKeyError = "Enter an API key to continue."
                    apiKeyFocused = true
                    return
                }
                apiKeyError = nil
                Task {
                    if let error = await store.signIn(apiKey: trimmed) {
                        apiKeyError = error
                        apiKeyFocused = true
                    }
                }
            }
            .disabled(store.isLoadingUsage)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            Button("Get a key") {
                apiKeyError = store.openKeyPage()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            Text("An API key is stored in the macOS Keychain.")
                .font(.caption)
                .tallySecondary()
                .padding(.top, 14)
        }
        .padding(16)
        .frame(width: 320)
        }
        .frame(maxHeight: 560)
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
                .tallySecondary()
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text("No requests yet today")
                .font(.headline)
            Text("Usage appears here once requests pass through the gateway. Monthly spend so far: \(store.money(store.ledger.monthSpend)).")
                .font(.subheadline)
                .tallySecondary()
                .multilineTextAlignment(.center)
            if let loadNotice = store.loadNotice, store.loadError == nil {
                Text(loadNotice)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            CapabilityStatus(report: store.capabilityReport, alwaysCopy: false, copy: store.copyCapabilityReport)
            Button("Refresh", action: store.refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer(minLength: 12)
            Text("Budget: \(store.money(0)) of \(store.money(store.dailyBudget)) today")
                .font(.caption)
                .tallySecondary()
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct LoadingUsageView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Tally")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            ProgressView()
            Text("Loading usage…")
                .font(.headline)
            Spacer(minLength: 12)
        }
        .padding(16)
        .frame(width: 320, height: 280)
    }
}

struct FailedUsageView: View {
    @Bindable var store: TallyStore

    var body: some View {
        VStack(spacing: 12) {
            Text("Tally")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            Text(store.loadError ?? "Couldn’t reach the gateway.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            CapabilityStatus(report: store.capabilityReport, alwaysCopy: false, copy: store.copyCapabilityReport)
            Button("Retry", action: store.reloadSpend)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Sign out") {
                store.signOut()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 12)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct CapabilityStatus: View {
    var report: CapabilityReport
    var alwaysCopy: Bool
    var copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLine("Spend and tokens", report.spend)
            statusLine("Models", report.models)
            statusLine("Request history", report.history)
            statusLine("Last synchronization", report.synchronization)
            if alwaysCopy || report.action != nil {
                Button("Copy report", action: copy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        Text("\(title) — \(value)")
            .font(.caption)
            .tallySecondary()
            .fixedSize(horizontal: false, vertical: true)
    }
}
