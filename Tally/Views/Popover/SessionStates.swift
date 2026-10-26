import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SignInView: View {
    @Bindable var store: TallyStore
    var dismiss: (() -> Void)? = nil
    @State private var apiKey = ""
    @State private var apiKeyError: String?
    @FocusState private var apiKeyFocused: Bool

    private var gatewayIsSet: Bool {
        !store.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverTitle {
                if let dismiss {
                    Button("Subscriptions", action: dismiss)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .tallyAccent()
                }
            }

            SpendCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: store.organization.isEmpty ? "Gateway" : store.organization)
                    TextField("https://gateway.example.com", text: $store.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Gateway")
                    Picker("Adapter", selection: $store.gatewayVersion) {
                        ForEach(GatewayVersion.allCases) { version in
                            Text(version.title).tag(version)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Adapter")
                    if store.showsCustomSpendURL {
                        SectionLabel(text: "Spend logs")
                        TextField("https://gateway.example.com/spend/logs/v2", text: store.spendURLBinding)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Spend logs")
                    }
                    SectionLabel(text: "Key page")
                    TextField("https://gateway.example.com/key", text: $store.keyPageURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Key page")
                    SectionLabel(text: "API key")
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("API key")
                        .focused($apiKeyFocused)
                    notice(apiKeyError)
                    notice(store.profileError)
                    notice(store.setupLinkError)
                    notice(store.authError)
                    if store.setupFailure != nil {
                        Button("Copy report", action: store.copyCapabilityReport)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            continueControl(prominent: gatewayIsSet)
            if store.showsExchange { exchangeControl }
            getKeyControl
            importControl(prominent: !gatewayIsSet)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func continueControl(prominent: Bool) -> some View {
        let button = Button(store.isLoadingUsage ? "Checking…" : "Connect") {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                apiKeyError = "Enter an API key to connect."
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
        if prominent {
            button.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
        } else {
            button.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
        }
    }

    private var exchangeControl: some View {
        Button(store.isLoadingUsage ? "Checking…" : "Sign in") {
            apiKeyError = store.beginTrackingSignIn()
        }
        .disabled(store.isLoadingUsage)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private var getKeyControl: some View {
        Button("Open key page") {
            apiKeyError = store.openKeyPage()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func importControl(prominent: Bool) -> some View {
        let button = Button(store.isLoadingSetup ? "Importing…" : "Import profile…") {
            store.profileError = nil
            ProfileFile.importInto(store) { store.profileError = $0 }
        }
        .disabled(store.isLoadingSetup)
        if prominent {
            button.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
        } else {
            button.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func notice(_ message: String?) -> some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
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
                .tallySecondary()
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text("No requests yet today")
                .font(.headline)
            Text("This month: \(store.money(store.ledger.monthSpend)).")
                .font(.subheadline)
                .tallySecondary()
            Button("Refresh", action: store.refresh)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer(minLength: 12)
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
            if let action = store.loadFailure?.action {
                Text(action)
                    .font(.caption)
                    .tallySecondary()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.loadFailure == GatewayClient.Failure.unapproved {
                Button("Allow this host") {
                    Task { _ = await store.approveSpendHost() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Retry", action: store.reloadSpend)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("Copy report", action: store.copyCapabilityReport)
                .buttonStyle(.bordered)
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
    var approve: () async -> String? = { nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLine("Spend and tokens", report.spend)
            statusLine("Models", report.models)
            statusLine("Request history", report.history)
            statusLine("Last synchronization", report.synchronization)
            if report.action == GatewayClient.Failure.unapproved.action {
                Button("Send the saved key to this host") {
                    Task { _ = await approve() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
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

struct ProfileSummary: View {
    var store: TallyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Source: \(store.profileSource)")
            Text("Profile host: \(store.displayedProfileHost)")
            Text(store.organization.isEmpty ? "Organization not set" : store.organization)
            Text("Spend host: \(store.spendHostLabel)")
            Text("Key page: \(store.keyPageHostLabel)")
            Text("Access: \(store.profilePermissions.joined(separator: ", ")). Scope: \(store.scopeTitle).")
            Text("The key is sent only to the spend host.")
        }
        .font(.caption)
        .tallySecondary()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectView: View {
    @Bindable var store: TallyStore

    var body: some View {
        Group {
            if store.isSignedIn {
                signedIn
            } else {
                SignInView(store: store)
            }
        }
        .onAppear { NSApp.activate() }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to gateway")
                .font(.headline)
            ProfileSummary(store: store)
            if store.isLoadingSetup {
                Text("Downloading the profile…")
                    .font(.caption)
                    .tallySecondary()
            }
            if let setupLinkError = store.setupLinkError {
                Text(setupLinkError)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.keyApproved {
                Button("Send the saved key to this host") {
                    Task { _ = await store.approveSpendHost() }
                }
                .buttonStyle(.borderedProminent)
            } else if store.setupLinkError == nil && !store.isLoadingSetup {
                Text("This Mac already has a key for this spend host.")
                    .font(.caption)
                    .tallySecondary()
            }
            Button("Copy report", action: store.copyCapabilityReport)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 360)
    }
}

@MainActor
enum ProfileFile {
    static func importInto(_ store: TallyStore, done: @escaping (String?) -> Void) {
        choose(save: false, prompt: "Import", name: nil) { url in
            guard let url else {
                done(nil)
                return
            }
            done(store.importProfile(from: url))
        }
    }

    static func exportFrom(_ store: TallyStore, done: @escaping (String?) -> Void) {
        choose(save: true, prompt: "Export", name: "tally-profile.json") { url in
            guard let url else {
                done(nil)
                return
            }
            done(store.exportProfile(to: url))
        }
    }

    /// MenuBarExtra cancels a panel opened in the same click. Present it on the next turn.
    private static func choose(save: Bool, prompt: String, name: String?, done: @escaping (URL?) -> Void) {
        let panel: NSSavePanel = save ? NSSavePanel() : NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = save
        panel.prompt = prompt
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        if let name {
            panel.nameFieldStringValue = name
        }
        if let open = panel as? NSOpenPanel {
            open.allowsMultipleSelection = false
            open.canChooseDirectories = false
            open.canChooseFiles = true
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                let url = response == .OK ? panel.url : nil
                Task { @MainActor in
                    done(url)
                }
            }
        }
    }
}
