/// The interaction an AI-enhanced feature lives inside.
///
/// The latency budget belongs to the interaction, not to the model. A category
/// suggestion that appears after the user has already tapped "Save" did not
/// arrive slowly; it did not arrive at all.
public enum Interaction: String, Sendable, CaseIterable {
    /// Inline while the user types: predictive input, autocomplete.
    case keystroke
    /// The response to a single tap: a preselected default, a suggestion chip.
    case tap
    /// An explicit submit: a search, a form, a "Done" button.
    case submit
    /// Work the user does not wait on: filing, tagging, indexing.
    case background

    /// The longest budget this library accepts for the interaction.
    ///
    /// These are this library's design defaults, chosen to sit under the point
    /// where the UI has visibly moved on. They are not Apple platform numbers.
    public var ceiling: Duration {
        switch self {
        case .keystroke: return .milliseconds(100)
        case .tap: return .milliseconds(250)
        case .submit: return .milliseconds(1_000)
        case .background: return .seconds(10)
        }
    }
}

/// Whether a wrong result can be taken back.
public enum UndoPolicy: Sendable, Equatable {
    case undoable(window: Duration)
    case irreversible
}

/// What the app does with the model's output.
public enum OutputRole: Sendable, Equatable {
    /// The user sees it and confirms it (a preselected default, a chip).
    case suggestion
    /// The app acts on it without asking (auto-file, auto-tag, auto-approve).
    case action(UndoPolicy)
}

/// How a contract is judged offline before it ships.
public struct EvalGate: Sendable, Equatable {
    /// Contract accuracy must beat the deterministic fallback by at least this
    /// much (0.10 = ten percentage points). If the model can't beat the rule,
    /// ship the rule.
    public var minMarginOverFallback: Double
    /// The highest acceptable share of golden cases where the model was
    /// confident *and* wrong. Those are the failures nobody sees.
    public var maxSilentErrorRate: Double

    public init(minMarginOverFallback: Double, maxSilentErrorRate: Double) {
        self.minMarginOverFallback = minMarginOverFallback
        self.maxSilentErrorRate = maxSilentErrorRate
    }
}

/// A failure-mode contract for one AI-enhanced feature.
///
/// The fallback is a required, non-optional initializer argument: a contract
/// without a deterministic answer for "the model is down, slow or unsure"
/// does not compile.
public struct FailureModeContract<Input: Sendable, Output: Sendable & Equatable>: Sendable {
    public let feature: String
    public let interaction: Interaction
    public let budget: Duration
    public let role: OutputRole
    /// Below this confidence the model's answer is discarded for the fallback.
    public let minConfidence: Double
    public let evalGate: EvalGate?
    public let fallback: @Sendable (Input) -> Output

    public init(
        feature: String,
        interaction: Interaction,
        budget: Duration,
        role: OutputRole,
        minConfidence: Double,
        evalGate: EvalGate?,
        fallback: @escaping @Sendable (Input) -> Output
    ) {
        self.feature = feature
        self.interaction = interaction
        self.budget = budget
        self.role = role
        self.minConfidence = minConfidence
        self.evalGate = evalGate
        self.fallback = fallback
    }

    /// A type-erased description for linting and display.
    public var summary: ContractSummary {
        ContractSummary(
            feature: feature,
            interaction: interaction,
            budget: budget,
            role: role,
            minConfidence: minConfidence,
            evalGate: evalGate
        )
    }
}

/// The parts of a contract the linter checks, without the generic types.
public struct ContractSummary: Sendable, Equatable {
    public var feature: String
    public var interaction: Interaction
    public var budget: Duration
    public var role: OutputRole
    public var minConfidence: Double
    public var evalGate: EvalGate?

    public init(
        feature: String,
        interaction: Interaction,
        budget: Duration,
        role: OutputRole,
        minConfidence: Double,
        evalGate: EvalGate?
    ) {
        self.feature = feature
        self.interaction = interaction
        self.budget = budget
        self.role = role
        self.minConfidence = minConfidence
        self.evalGate = evalGate
    }
}
