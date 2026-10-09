public struct GoldenCase<Input: Sendable, Output: Sendable & Equatable>: Sendable {
    public var input: Input
    public var expected: Output

    public init(_ input: Input, expected: Output) {
        self.input = input
        self.expected = expected
    }
}

/// What an AI-enhanced feature does on a golden set, measured three ways.
public struct EvalReport: Sendable, Equatable {
    public var cases: Int
    /// Correct answers if the app always used the model, whatever its confidence.
    public var modelCorrect: Int
    /// Correct answers if the app always used the deterministic fallback.
    public var fallbackCorrect: Int
    /// Correct answers under the contract: model when confident, fallback otherwise.
    public var contractCorrect: Int
    /// Cases where the model cleared the confidence floor.
    public var confident: Int
    /// Cases where the model cleared the floor and was wrong. Nobody sees these.
    public var silentErrors: Int

    public var modelAccuracy: Double { ratio(modelCorrect) }
    public var fallbackAccuracy: Double { ratio(fallbackCorrect) }
    public var contractAccuracy: Double { ratio(contractCorrect) }
    public var coverage: Double { ratio(confident) }
    public var silentErrorRate: Double { ratio(silentErrors) }

    private func ratio(_ value: Int) -> Double {
        cases == 0 ? 0 : Double(value) / Double(cases)
    }

    /// Reasons the report fails the gate. Empty means it passes.
    public func failures(against gate: EvalGate) -> [String] {
        var reasons: [String] = []
        if cases == 0 {
            reasons.append("The golden set is empty.")
            return reasons
        }
        let margin = contractAccuracy - fallbackAccuracy
        // Compare in whole basis points so 0.1 vs 0.0999999 float noise can't flip a gate.
        if bp(margin) < bp(gate.minMarginOverFallback) {
            reasons.append("Beats the fallback by \(pct(margin)); the gate needs \(pct(gate.minMarginOverFallback)).")
        }
        if bp(silentErrorRate) > bp(gate.maxSilentErrorRate) {
            reasons.append("\(silentErrors) of \(cases) answers were confident and wrong (\(pct(silentErrorRate))); the gate allows \(pct(gate.maxSilentErrorRate)).")
        }
        return reasons
    }

    public func passes(_ gate: EvalGate) -> Bool { failures(against: gate).isEmpty }
}

func bp(_ value: Double) -> Int { Int((value * 10_000).rounded()) }

/// Formats 0.875 as "87.5%".
public func pct(_ value: Double) -> String {
    let tenths = Int((value * 1_000).rounded())
    let sign = tenths < 0 ? "-" : ""
    let magnitude = abs(tenths)
    return "\(sign)\(magnitude / 10).\(magnitude % 10)%"
}

extension FailureModeContract {
    /// Runs the golden set offline. Latency is not measured here; a model that
    /// throws counts as unavailable and the fallback answers.
    public func evaluate<M: DecisionModel>(
        _ golden: [GoldenCase<Input, Output>],
        using model: M
    ) async -> EvalReport where M.Input == Input, M.Output == Output {
        var report = EvalReport(cases: golden.count, modelCorrect: 0, fallbackCorrect: 0, contractCorrect: 0, confident: 0, silentErrors: 0)
        for item in golden {
            let ruleAnswer = fallback(item.input)
            let ruleRight = ruleAnswer == item.expected
            if ruleRight { report.fallbackCorrect += 1 }

            guard let decision = try? await model.decide(item.input) else {
                if ruleRight { report.contractCorrect += 1 }
                continue
            }
            let modelRight = decision.value == item.expected
            if modelRight { report.modelCorrect += 1 }

            if decision.confidence >= minConfidence {
                report.confident += 1
                if modelRight {
                    report.contractCorrect += 1
                } else {
                    report.silentErrors += 1
                }
            } else if ruleRight {
                report.contractCorrect += 1
            }
        }
        return report
    }
}
