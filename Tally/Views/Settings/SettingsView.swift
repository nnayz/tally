import SwiftUI

struct SettingsRoot: View {
    @Bindable var store: TallyStore

    var body: some View {
        TabView(selection: $store.settingsTab) {
            GeneralSettings(store: store)
                .tag(SettingsTab.general)
                .tabItem { Label("General", systemImage: "record.circle") }
            GatewaySettings(store: store)
                .tag(SettingsTab.gateway)
                .tabItem { Label("Gateway", systemImage: "plus.circle") }
            BudgetsSettings(store: store)
                .tag(SettingsTab.budgets)
                .tabItem { Label("Budgets", systemImage: "list.bullet") }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .frame(width: 560, height: 500)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: TallyStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                Picker("Menu bar shows", selection: $store.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            }
            Section {
                ForEach(WidgetSource.allCases) { source in
                    Toggle(source.title, isOn: store.sourceBinding(source))
                }
            } header: {
                Text("Shown on the menu bar")
            } footer: {
                Text("Turn on only the plans you use. Gateway is spend from your gateway. Codex, Claude, Grok, and Cursor use the sign-in already on this Mac.")
                    .tallySecondary()
            }
            Section {
                Picker("Refresh interval", selection: $store.refreshSeconds) {
                    Text("Every 15 seconds").tag(15)
                    Text("Every 30 seconds").tag(30)
                    Text("Every 60 seconds").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            } footer: {
                Text("Reloads Codex, Claude, Grok, and Cursor quotas on this Mac.")
                    .tallySecondary()
            }
            Section {
                Picker("Currency", selection: $store.currencyCode) {
                    ForEach(Format.currencies) { currency in
                        Text(currency.label).tag(currency.code)
                    }
                }
                if store.currencyCode != "USD" {
                    TextField(
                        "1 USD equals",
                        value: $store.unitsPerUSD,
                        format: .number.precision(.fractionLength(0...6))
                    )
                }
            } footer: {
                if store.currencyCode != "USD" {
                    Text("Gateway prices are in USD. The rate only changes what you see.")
                        .tallySecondary()
                }
            }
            Section {
                Picker("Day starts at", selection: $store.dayStart) {
                    ForEach(DayStart.allCases) { start in
                        Text(start.title).tag(start)
                    }
                }
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            } footer: {
                Text("Budgets reset at the selected time. Use UTC to match the gateway’s billing day.")
                    .tallySecondary()
            }
        }
        .formStyle(.grouped)
    }
}

private struct GatewaySettings: View {
    @Bindable var store: TallyStore
    @Environment(\.colorScheme) private var scheme
    @State private var replacingKey = false
    @State private var draftKey = ""
    @State private var keyError: String?
    @State private var linkNotice: String?
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if store.isSignedIn {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(TallyPalette.statusGreen(scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected")
                                .font(.headline)
                            Text("API key stored in Keychain")
                                .font(.subheadline)
                            if let loadNotice = store.loadNotice, store.loadError == nil {
                                Text(loadNotice)
                                    .font(.caption)
                                    .tallySecondary()
                            }
                            CapabilityStatus(
                                report: store.capabilityReport,
                                alwaysCopy: true,
                                copy: store.copyCapabilityReport,
                                approve: store.approveSpendHost
                            )
                        }
                        Spacer()
                        Button("Sign Out") { confirmSignOut = true }
                            .confirmationDialog("Sign out?", isPresented: $confirmSignOut) {
                                Button("Sign out", role: .destructive) {
                                    store.signOut()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This removes the saved API key from Keychain. Revoke it at the gateway if you no longer want it to work.")
                            }
                    }
                }
            } else {
                Section {
                    Text("Not connected. Open Tally from the menu bar to sign in.")
                        .tallySecondary()
                }
            }
            Section {
                ProfileSummary(store: store)
                TextField("Organization", text: $store.organization)
                Picker("Scope", selection: $store.profileScope) {
                    Text("This key").tag("this key")
                    Text("This user").tag("this user")
                    Text("Team").tag("team")
                }
                TextField("Gateway URL", text: $store.gatewayURL)
                Picker("Adapter", selection: $store.gatewayVersion) {
                    ForEach(GatewayVersion.allCases) { version in
                        Text(version.title).tag(version)
                    }
                }
                TextField("Spend URL", text: store.spendURLBinding)
                TextField("Key page URL", text: $store.keyPageURL)
                TextField("Help URL", text: $store.helpURL)
                LabeledContent("Profile") {
                    HStack {
                        Button("Import…") { keyError = ProfileFile.importInto(store) }
                        Button("Export…") { keyError = ProfileFile.exportFrom(store) }
                    }
                }
                TextField("Hosted profile URL", text: $store.hostedProfileURL)
                    .onChange(of: store.hostedProfileURL) { _, _ in
                        linkNotice = nil
                    }
                LabeledContent("Setup link") {
                    Button("Copy setup link") {
                        if let error = store.copySetupLink() {
                            keyError = error
                            linkNotice = nil
                        } else {
                            keyError = nil
                            linkNotice = "Copied the setup link."
                        }
                    }
                }
                if let linkNotice {
                    Text(linkNotice)
                        .foregroundStyle(.primary)
                }
                LabeledContent("Key page") {
                    Button("Get a key") {
                        keyError = store.openKeyPage()
                    }
                }
                LabeledContent("API key") {
                    if replacingKey {
                        HStack {
                            SecureField("New API key", text: $draftKey)
                            Button(store.isLoadingUsage ? "Checking…" : "Save") {
                                Task {
                                    if let error = await store.replaceAPIKey(draftKey) {
                                        keyError = error
                                    } else {
                                        draftKey = ""
                                        replacingKey = false
                                        keyError = nil
                                    }
                                }
                            }
                            .disabled(store.isLoadingUsage || draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        HStack {
                            Text(store.isSignedIn ? store.maskedAPIKey : "Not set")
                                .tallySecondary()
                                .monospaced()
                            Button("Change…") { replacingKey = true }
                        }
                    }
                }
                if let keyError {
                    Text(keyError)
                        .foregroundStyle(.primary)
                }

            } header: {
                Text("Create connection profile")
            } footer: {
                Text("Export the profile, host that file at an https address, paste the address, and copy the setup link. The link does not include a key. API keys are stored in the macOS Keychain. Prompts and outputs are never stored. Replacing or deleting the key here does not revoke it at the gateway.")
                    .tallySecondary()
            }
        }
        .formStyle(.grouped)
    }
}

private struct BudgetsSettings: View {
    @Bindable var store: TallyStore
    @State private var showCaps = false

    var body: some View {
        Form {
            Section {
                TextField("Daily budget", value: displayBudget(\.dailyBudget), format: .currency(code: store.currencyCode))
                TextField("Monthly budget", value: displayBudget(\.monthlyBudget), format: .currency(code: store.currencyCode))
            }
            Section {
                LabeledContent("Warning threshold") {
                    HStack(spacing: 8) {
                        Slider(value: $store.warningThreshold, in: 0.5...0.95, step: 0.05)
                        Text("\(Int((store.warningThreshold * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 240)
                }
                Toggle("Notify when exceeded", isOn: $store.notifyWhenExceeded)
                Toggle("Notify at warning", isOn: $store.notifyAtWarning)
                LabeledContent("Per-model limits") {
                    Button("Configure…") { showCaps = true }
                }
            } footer: {
                Text("Budgets are monitored only — Tally does not block requests. Enforce hard limits in the gateway.")
                    .tallySecondary()
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCaps) {
            ModelCapsSheet(store: store)
        }
    }

    private func displayBudget(_ keyPath: ReferenceWritableKeyPath<TallyStore, Double>) -> Binding<Double> {
        Binding {
            store.displayAmount(store[keyPath: keyPath])
        } set: { shown in
            store[keyPath: keyPath] = store.usdAmount(shown)
        }
    }
}

private struct ModelCapsSheet: View {
    @Bindable var store: TallyStore
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-model limits")
                .font(.headline)
            Text("Optional monthly caps. Tally only warns — it does not block traffic.")
                .font(.callout)
                .tallySecondary()
            if store.knownModels.isEmpty {
                Text("Limits can be set after usage loads.")
                    .tallySecondary()
            }
            ForEach(store.knownModels) { model in
                HStack {
                    ModelDot(color: model.color)
                    Text(model.id)
                    Spacer()
                    TextField("No cap", text: draftBinding(model))
                        .frame(width: 120)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func draftBinding(_ model: AIModel) -> Binding<String> {
        let key = model.rawValue
        return Binding {
            if let draft = drafts[key] {
                return draft
            }
            guard let cap = store.modelCaps[key] else { return "" }
            return store.money(cap)
        } set: { newValue in
            drafts[key] = newValue
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                store.modelCaps[key] = nil
                return
            }
            guard let shown = parseDisplayAmount(trimmed), shown > 0 else { return }
            store.modelCaps[key] = store.usdAmount(shown)
        }
    }

    private func parseDisplayAmount(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = store.currencyCode
        if let number = formatter.number(from: text) {
            return number.doubleValue
        }
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue
    }
}
