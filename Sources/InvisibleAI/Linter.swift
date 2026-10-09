public struct Finding: Sendable, Equatable {
    public enum Severity: String, Sendable, Comparable {
        case warning, error
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public enum Rule: String, Sendable, CaseIterable {
        /// The app acts on a model output and the user cannot take it back.
        case irreversibleAction
        /// The budget is longer than the interaction allows.
        case budgetOverInteractionCeiling
        /// Nothing measures the feature before it ships.
        case missingEvalGate
        /// The gate lets the model ship without beating the fallback.
        case nonPositiveMargin
        /// An action runs on any confidence the model reports.
        case actionWithoutConfidenceFloor
        /// minConfidence is outside 0...1, so it is either always or never met.
        case confidenceOutOfRange
    }

    public var severity: Severity
    public var rule: Rule
    public var message: String
}

/// Static checks a lead can run in CI over every AI-enhanced feature's contract.
public enum ContractLinter {
    /// Below this floor, an `action` is effectively unguarded.
    public static let actionConfidenceFloor = 0.5

    public static func audit(_ contract: ContractSummary) -> [Finding] {
        var findings: [Finding] = []

        if contract.minConfidence < 0 || contract.minConfidence > 1 {
            findings.append(Finding(
                severity: .error,
                rule: .confidenceOutOfRange,
                message: "minConfidence \(contract.minConfidence) is outside 0...1."
            ))
        }

        if case .action(let undo) = contract.role {
            if undo == .irreversible {
                findings.append(Finding(
                    severity: .error,
                    rule: .irreversibleAction,
                    message: "Invisible and irreversible: nobody sees it fail and nobody can undo it. Make it a suggestion or give it an undo window."
                ))
            }
            if contract.minConfidence < actionConfidenceFloor {
                findings.append(Finding(
                    severity: .error,
                    rule: .actionWithoutConfidenceFloor,
                    message: "Acts on any answer at or above \(contract.minConfidence) confidence; actions need a floor of at least \(actionConfidenceFloor)."
                ))
            }
        }

        if contract.budget > contract.interaction.ceiling {
            findings.append(Finding(
                severity: .warning,
                rule: .budgetOverInteractionCeiling,
                message: "Budget \(contract.budget) exceeds the \(contract.interaction.rawValue) ceiling of \(contract.interaction.ceiling). The UI will have moved on."
            ))
        }

        if let gate = contract.evalGate {
            if gate.minMarginOverFallback <= 0 {
                findings.append(Finding(
                    severity: .error,
                    rule: .nonPositiveMargin,
                    message: "The eval gate passes a model that does not beat the deterministic fallback."
                ))
            }
        } else {
            findings.append(Finding(
                severity: .error,
                rule: .missingEvalGate,
                message: "No offline eval gate. Nothing measures this feature before it ships."
            ))
        }

        return findings.sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : lhs.rule.rawValue < rhs.rule.rawValue
        }
    }
}
