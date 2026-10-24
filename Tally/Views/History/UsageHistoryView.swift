import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageHistoryView: View {
    @Bindable var store: TallyStore
    @State private var selection = Set<UsageRequest.ID>()
    @State private var sortOrder = [KeyPathComparator(\UsageRequest.time, order: .reverse)]
    @State private var limit = 50
    @State private var query = ""
    @State private var didPreselect = false
    @State private var exportError = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
        }
        .navigationTitle("Usage History")
        .searchable(text: $query, prompt: "Search requests")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV…", action: export)
            }
        }
        .alert("Couldn't save the CSV", isPresented: $exportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that you can write to that folder and try again.")
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .frame(minWidth: 960, minHeight: 560)
        .onAppear(perform: preselect)
        .onChange(of: store.historyRange) { _, _ in limit = 50 }
        .onChange(of: store.historyView) { _, _ in limit = 50 }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Views")
                    .font(.caption2.weight(.semibold))
                    .tallySecondary()
                    .textCase(.uppercase)
                    .accessibilityLabel("Views")
                    .padding(.horizontal, 8)
                List(HistoryView.allCases, selection: $store.historyView) { view in
                    Text(view.title).tag(view)
                }
                .listStyle(.sidebar)
                .frame(height: 148)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Filters")
                    .font(.caption2.weight(.semibold))
                    .tallySecondary()
                    .textCase(.uppercase)
                    .accessibilityLabel("Filters")
                filterMenu("Date range", selection: $store.historyRange) {
                    ForEach(DateRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                filterMenu("Model", selection: $store.historyModel) {
                    Text("All models").tag("All models")
                    ForEach(AIModel.allCases) { model in
                        Text(model.rawValue).tag(model.rawValue)
                    }
                }
                filterMenu("Conversation", selection: $store.historyConversation) {
                    Text("All").tag("All")
                    ForEach(Ledger.conversations, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                filterMenu("Status", selection: $store.historyStatus) {
                    ForEach(StatusFilter.allCases) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
            }
            .padding(.horizontal, 12)
            Spacer()
        }
        .padding(.top, 12)
    }

    private func filterMenu<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .tallySecondary()
            Picker(title, selection: selection, content: content)
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            kpiStrip
            Group {
                switch store.historyView {
                case .byModel:
                    modelTable
                case .byConversation:
                    conversationTable
                case .allRequests, .errors:
                    requestTable
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            footer
        }
        .padding(16)
    }

    private var kpiStrip: some View {
        let rows = searched(store.filteredRequests())
        let spend = rows.reduce(0) { $0 + $1.cost }
        let input = rows.reduce(0) { $0 + $1.input }
        let output = rows.reduce(0) { $0 + $1.output }
        let errors = rows.filter(\.isError).count
        let errorRate = rows.isEmpty ? 0 : Double(errors) / Double(rows.count) * 100
        return HStack(spacing: 8) {
            kpi("Spend", store.money(spend))
            kpi("Requests", Format.count(rows.count))
            kpi("Input tokens", Format.tokens(input))
            kpi("Output tokens", Format.tokens(output))
            kpi("Errors", "\(Format.count(errors)) (\(String(format: "%.1f", errorRate))%)")
        }
    }

    private func kpi(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .tallySecondary()
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var requestRows: [UsageRequest] {
        Array(searched(store.filteredRequests()).sorted(using: sortOrder).prefix(limit))
    }

    private var requestTable: some View {
        Table(requestRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.time) { row in
                Text(Format.requestTime(row.time)).monospacedDigit()
            }
            .width(min: 140)
            TableColumn("Model", value: \.model) { row in
                HStack(spacing: 6) {
                    ModelDot(color: row.model.color)
                    Text(row.model.rawValue)
                }
            }
            .width(min: 130)
            TableColumn("Conversation", value: \.conversation) { row in
                Text(row.conversation)
                    .lineLimit(1)
            }
            TableColumn("Input", value: \.input) { row in
                Text(row.isError ? "—" : Format.count(row.input))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70)
            TableColumn("Output", value: \.output) { row in
                Text(row.isError ? "—" : Format.count(row.output))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70)
            TableColumn("Cost", value: \.cost) { row in
                Text(store.money(row.cost, digits: 4))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80)
            TableColumn("Status", value: \.status) { row in
                StatusPill(status: row.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(70)
        }
    }

    private var modelTable: some View {
        let rows = modelAggregates
        return Table(rows) {
            TableColumn("Model") { row in
                HStack(spacing: 6) {
                    ModelDot(color: row.model.color)
                    Text(row.model.rawValue)
                }
            }
            TableColumn("Requests") { row in
                Text(Format.count(row.requests)).monospacedDigit()
            }
            TableColumn("Input") { row in
                Text(Format.tokens(row.input)).monospacedDigit()
            }
            TableColumn("Output") { row in
                Text(Format.tokens(row.output)).monospacedDigit()
            }
            TableColumn("Cost") { row in
                Text(store.money(row.cost)).monospacedDigit()
            }
            TableColumn("Errors") { row in
                Text(Format.count(row.errors)).monospacedDigit()
            }
        }
    }

    private var conversationTable: some View {
        Table(conversationAggregates) {
            TableColumn("Conversation") { row in
                Text(row.name)
            }
            TableColumn("Requests") { row in
                Text(Format.count(row.requests)).monospacedDigit()
            }
            TableColumn("Input") { row in
                Text(Format.tokens(row.input)).monospacedDigit()
            }
            TableColumn("Output") { row in
                Text(Format.tokens(row.output)).monospacedDigit()
            }
            TableColumn("Cost") { row in
                Text(store.money(row.cost)).monospacedDigit()
            }
        }
    }

    private var footer: some View {
        let total = searched(store.filteredRequests()).count
        let shown = min(limit, total)
        return HStack {
            if store.historyView == .allRequests || store.historyView == .errors {
                Text("Showing 1–\(shown) of \(Format.count(total)) · \(selection.count) selected")
                    .tallySecondary()
            } else {
                Text("^[\(total) request](inflect: true) in this view")
                    .tallySecondary()
            }
            Spacer()
            Button("Load more") { limit += 50 }
                .buttonStyle(.plain)
                .tallyAccent()
                .disabled(shown >= total || store.historyView == .byModel || store.historyView == .byConversation)
        }
        .font(.subheadline)
    }

    private var modelAggregates: [ModelAggregate] {
        let rows = searched(store.filteredRequests())
        return AIModel.allCases.compactMap { model in
            let matching = rows.filter { $0.model == model }
            guard !matching.isEmpty else { return nil }
            return ModelAggregate(
                model: model,
                requests: matching.count,
                input: matching.reduce(0) { $0 + $1.input },
                output: matching.reduce(0) { $0 + $1.output },
                cost: matching.reduce(0) { $0 + $1.cost },
                errors: matching.filter(\.isError).count
            )
        }
        .sorted { $0.cost > $1.cost }
    }

    private var conversationAggregates: [ConversationAggregate] {
        let rows = searched(store.filteredRequests()).filter { $0.conversation != "—" }
        let names = Set(rows.map(\.conversation))
        return names.map { name in
            let matching = rows.filter { $0.conversation == name }
            return ConversationAggregate(
                name: name,
                requests: matching.count,
                input: matching.reduce(0) { $0 + $1.input },
                output: matching.reduce(0) { $0 + $1.output },
                cost: matching.reduce(0) { $0 + $1.cost }
            )
        }
        .sorted { $0.cost > $1.cost }
    }

    private func searched(_ rows: [UsageRequest]) -> [UsageRequest] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.model.rawValue.localizedCaseInsensitiveContains(needle)
                || $0.conversation.localizedCaseInsensitiveContains(needle)
                || String($0.status).contains(needle)
                || ($0.isError ? "error" : "ok").localizedCaseInsensitiveContains(needle)
        }
    }

    private func preselect() {
        guard !didPreselect else { return }
        didPreselect = true
        selection = [store.ledger.highlightedRequestID]
    }

    private func export() {
        let rows = searched(store.filteredRequests()).sorted(using: sortOrder)
        let header = "time,model,conversation,input,output,cost,status"
        let lines = rows.map { row in
            [
                Format.requestTime(row.time),
                row.model.rawValue,
                csv(row.conversation),
                String(row.input),
                String(row.output),
                String(format: "%.4f", row.cost),
                String(row.status),
            ].joined(separator: ",")
        }
        let csvText = ([header] + lines).joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Tally Usage.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csvText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = true
            }
        }
    }

    private func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private struct StatusPill: View {
    var status: Int

    var body: some View {
        Text(status == 200 ? "OK" : "\(status)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((status == 200 ? Color.green : Color.red).opacity(0.16), in: Capsule())
    }
}

private struct ModelAggregate: Identifiable {
    var model: AIModel
    var requests: Int
    var input: Int
    var output: Int
    var cost: Double
    var errors: Int
    var id: String { model.id }
}

private struct ConversationAggregate: Identifiable {
    var name: String
    var requests: Int
    var input: Int
    var output: Int
    var cost: Double
    var id: String { name }
}
