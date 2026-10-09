import SwiftUI
import InvisibleAI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum DemoTab: String, CaseIterable, Identifiable {
    case live, eval, contracts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live"
        case .eval: return "Eval"
        case .contracts: return "Contracts"
        }
    }
}

/// Launch arguments (CI uses these for screenshots):
///   -tab live|eval|contracts
///   -condition healthy|slow|stuck|offline|overconfident
///   -merchant "Uber Eats"
///   -threshold 0.7|0.8
struct RootView: View {
    @State private var tab: DemoTab
    @State private var condition: ModelCondition
    @State private var merchant: String
    @State private var threshold: Double

    init() {
        let defaults = UserDefaults.standard
        _tab = State(initialValue: DemoTab(rawValue: defaults.string(forKey: "tab") ?? "") ?? .live)
        _condition = State(initialValue: ModelCondition(rawValue: defaults.string(forKey: "condition") ?? "") ?? .healthy)
        _merchant = State(initialValue: defaults.string(forKey: "merchant") ?? "Whole Foods Market")
        let raw = defaults.double(forKey: "threshold")
        _threshold = State(initialValue: raw > 0 ? raw : 0.8)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .live: LiveView(condition: $condition, merchant: $merchant, threshold: threshold)
                case .eval: EvalView(threshold: $threshold)
                case .contracts: ContractsView()
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $tab) {
                    ForEach(DemoTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationTitle("Invisible AI")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Live

func milliseconds(_ d: Duration) -> Int64 {
    let (seconds, attoseconds) = d.components
    return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
}

struct LiveView: View {
    @Binding var condition: ModelCondition
    @Binding var merchant: String
    let threshold: Double

    @State private var resolution: Resolution<ExpenseCategory>?
    @State private var running = false

    var body: some View {
        Form {
            Section {
                TextField("Merchant", text: $merchant)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Picker("Model", selection: $condition) {
                    ForEach(ModelCondition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("New expense")
            } footer: {
                Text("Contract: \"Category default\" · tap · 250 ms budget · suggestion · min confidence \(String(format: "%.2f", threshold))")
            }

            Section("Category (preselected)") {
                if let resolution {
                    HStack {
                        Text(resolution.value.rawValue.capitalized)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        SourceBadge(source: resolution.source)
                    }
                    LabeledContent("Answered in", value: "\(milliseconds(resolution.elapsed)) ms")
                    LabeledContent("Why", value: explanation(resolution.source))
                } else if running {
                    ProgressView()
                } else {
                    Text("Tap Resolve").foregroundStyle(.secondary)
                }
                Button(running ? "Resolving..." : "Resolve") { Task { await run() } }
                    .disabled(running)
            }

            Section("Try") {
                ForEach(["Uber Eats", "Sweetgreen", "Lyft Ride", "Apple Store"], id: \.self) { name in
                    Button(name) {
                        merchant = name
                        Task { await run() }
                    }
                }
            }
        }
        .task { await run() }
        .onChange(of: condition) { Task { await run() } }
    }

    private func run() async {
        running = true
        resolution = nil
        let contract = SampleExpenses.categoryDefault(minConfidence: threshold)
        resolution = await contract.resolve(merchant, using: ScriptedMerchantClassifier(condition: condition))
        running = false
    }

    private func explanation(_ source: ResolutionSource) -> String {
        switch source {
        case .model: return "Model, above the floor"
        case .fallback(.overBudget): return "Model missed 250 ms; keyword rule"
        case .fallback(.unavailable): return "Model unavailable; keyword rule"
        case .fallback(.lowConfidence): return "Model unsure; keyword rule"
        }
    }
}

struct SourceBadge: View {
    let source: ResolutionSource
    var body: some View {
        let (text, color): (String, Color) = {
            switch source {
            case .model(let c): return ("model \(String(format: "%.2f", c))", .blue)
            case .fallback(let r): return ("fallback: \(r.rawValue)", .orange)
            }
        }()
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Eval

struct EvalView: View {
    @Binding var threshold: Double
    @State private var healthy: EvalReport?
    @State private var overconfident: EvalReport?

    var body: some View {
        List {
            Section {
                Picker("Confidence floor", selection: $threshold) {
                    Text("0.70").tag(0.7)
                    Text("0.80").tag(0.8)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("24 labelled merchants. Gate: beat the keyword rule by 10 points, at most 5% confident-and-wrong.")
            }
            if let healthy { ReportSection(title: "Healthy model", report: healthy) }
            if let overconfident { ReportSection(title: "Overconfident model", report: overconfident) }
        }
        .task(id: threshold) {
            let contract = SampleExpenses.categoryDefault(minConfidence: threshold)
            healthy = await contract.evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier(condition: .healthy))
            overconfident = await contract.evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier(condition: .overconfident))
        }
    }
}

struct ReportSection: View {
    let title: String
    let report: EvalReport
    var body: some View {
        let failures = report.failures(against: SampleExpenses.silentGate)
        Section {
            LabeledContent("Keyword rule alone", value: pct(report.fallbackAccuracy))
            LabeledContent("Model alone", value: pct(report.modelAccuracy))
            LabeledContent("Contract (model if sure)", value: pct(report.contractAccuracy))
            LabeledContent("Model answered", value: "\(report.confident) of \(report.cases)")
            LabeledContent("Confident and wrong", value: "\(report.silentErrors) (\(pct(report.silentErrorRate)))")
                .foregroundStyle(report.silentErrors > 0 ? .red : .primary)
            if failures.isEmpty {
                Label("Gate: PASS", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                ForEach(failures, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
        } header: {
            Text(title)
        }
    }
}

// MARK: - Contracts

struct ContractsView: View {
    var body: some View {
        List {
            ForEach(SampleExpenses.allSummaries, id: \.feature) { summary in
                let findings = ContractLinter.audit(summary)
                Section {
                    LabeledContent("Interaction", value: "\(summary.interaction.rawValue) · \(summary.budget)")
                    LabeledContent("Role", value: role(summary.role))
                    LabeledContent("Min confidence", value: String(format: "%.2f", summary.minConfidence))
                    if findings.isEmpty {
                        Label("Lint clean", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    ForEach(findings, id: \.rule) { finding in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.rule.rawValue).font(.caption.monospaced().weight(.semibold))
                                Text(finding.message).font(.footnote)
                            }
                        } icon: {
                            Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(finding.severity == .error ? .red : .orange)
                        }
                    }
                } header: {
                    Text(summary.feature)
                }
            }
        }
    }

    private func role(_ role: OutputRole) -> String {
        switch role {
        case .suggestion: return "suggestion"
        case .action(.irreversible): return "action, irreversible"
        case .action(.undoable(let window)): return "action, undo for \(window)"
        }
    }
}
