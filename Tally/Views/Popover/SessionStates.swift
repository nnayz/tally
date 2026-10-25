import AppKit
import SwiftUI

struct SignInView: View {
    @Bindable var store: TallyStore
    @State private var apiKey = ""
    @State private var apiKeyError: String?
    @FocusState private var apiKeyFocused: Bool

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
            }
            .padding(.top, 18)

            if store.authMethod == .apiKey {
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
                Button("Use browser sign-in") {
                    apiKeyError = nil
                    store.authMethod = .browser
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            } else {
                Button("Sign in with Browser") {
                    store.authMethod = .apiKey
                    if let url = URL(string: store.gatewayURL), url.scheme == "https" {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                Button("Use API key instead") {
                    store.authMethod = .apiKey
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }

            Text("An API key is stored in the macOS Keychain.")
                .font(.caption)
                .tallySecondary()
                .padding(.top, 14)
        }
        .padding(16)
        .frame(width: 320)
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
            if let loadError = store.loadError {
                Text(loadError)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            Button("Refresh", action: store.refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer(minLength: 12)
            Text("Budget: \(store.money(0)) of \(store.money(store.dailyBudget)) today")
                .font(.caption)
                .tallySecondary()
        }
        .padding(16)
        .frame(width: 320, height: 360)
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
        .frame(width: 320, height: 280)
    }
}
