import AppKit
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
                Picker("Currency", selection: $store.currencyCode) {
                    Text("USD ($)").tag("USD")
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
                            Text("\(store.accountEmail) · team: \(store.teamName)")
                                .font(.subheadline)
                            Text("Last sync \(Format.clock(store.lastUpdated)) · token expires in ^[\(daysUntilExpiry) day](inflect: true)")
                                .font(.caption)
                                .tallySecondary()
                        }
                        Spacer()
                        Button("Sign Out") { confirmSignOut = true }
                            .confirmationDialog("Sign out?", isPresented: $confirmSignOut) {
                                Button("Sign out", role: .destructive) {
                                    store.signOut()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This removes the saved API key from Keychain.")
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
                TextField("Gateway URL", text: $store.gatewayURL)
                Picker("Authentication", selection: $store.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                LabeledContent("API key") {
                    if replacingKey {
                        HStack {
                            SecureField("New API key", text: $draftKey)
                            Button("Save") {
                                store.replaceAPIKey(draftKey)
                                draftKey = ""
                                replacingKey = false
                            }
                            .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
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
                LabeledContent("Open management portal") {
                    Button("Open ↗") {
                        if let url = URL(string: store.gatewayURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } footer: {
                Text("Keys and tokens are stored in the macOS Keychain. Prompts and outputs are never downloaded — metadata only.")
                    .tallySecondary()
            }
        }
        .formStyle(.grouped)
    }

    private var daysUntilExpiry: Int {
        let seconds = store.tokenExpires.timeIntervalSince(Date())
        return max(Int((seconds / 86_400).rounded()), 0)
    }
}

private struct BudgetsSettings: View {
    @Bindable var store: TallyStore
    @State private var showCaps = false

    var body: some View {
        Form {
            Section {
                TextField("Daily budget", value: $store.dailyBudget, format: .currency(code: store.currencyCode))
                TextField("Monthly budget", value: $store.monthlyBudget, format: .currency(code: store.currencyCode))
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
            ForEach(AIModel.allCases) { model in
                HStack {
                    ModelDot(color: model.color)
                    Text(model.rawValue)
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
            let numeric = trimmed.filter { $0.isNumber || $0 == "." }
            guard let value = Double(numeric) else { return }
            store.modelCaps[key] = value > 0 ? value : nil
        }
    }
}
