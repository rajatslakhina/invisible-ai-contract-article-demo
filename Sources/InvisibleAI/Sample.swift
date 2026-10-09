import Foundation

/// A small expense app used by the demo and the tests. The data is
/// constructed for illustration; it is not a benchmark of any real model.
public enum ExpenseCategory: String, Sendable, CaseIterable, Equatable {
    case groceries, dining, transport, travel, software, utilities, other
}

/// How the scripted model behaves, so every failure mode can be shown on demand.
public enum ModelCondition: String, Sendable, CaseIterable {
    /// Answers in ~40 ms with its normal confidences.
    case healthy
    /// Answers correctly but takes 600 ms (honours cancellation).
    case slow
    /// Takes 1.5 s and ignores cancellation, like a blocking SDK call.
    case stuck
    /// Throws immediately.
    case offline
    /// Same answers as healthy, but reports at least 0.95 confidence on everything.
    case overconfident
}

public struct ModelOffline: Error {}

/// A deterministic stand-in for an on-device classifier.
public struct ScriptedMerchantClassifier: DecisionModel {
    public typealias Input = String
    public typealias Output = ExpenseCategory

    public var condition: ModelCondition

    public init(condition: ModelCondition = .healthy) {
        self.condition = condition
    }

    public func decide(_ merchant: String) async throws -> Decision<ExpenseCategory> {
        switch condition {
        case .offline:
            throw ModelOffline()
        case .slow:
            try await Task.sleep(for: .milliseconds(600))
        case .stuck:
            await uncancellableWait(seconds: 1.5)
        case .healthy, .overconfident:
            try await Task.sleep(for: .milliseconds(40))
        }
        let base = SampleExpenses.modelAnswers[merchant] ?? Decision(value: .other, confidence: 0.30)
        if condition == .overconfident {
            return Decision(value: base.value, confidence: max(base.confidence, 0.95))
        }
        return base
    }
}

/// Waits on a dispatch timer, which Swift task cancellation cannot interrupt.
func uncancellableWait(seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}

public enum SampleExpenses {
    /// The deterministic fallback: a handful of keyword rules, then `.other`.
    public static func keywordRule(_ merchant: String) -> ExpenseCategory {
        let name = merchant.lowercased()
        let rules: [(String, ExpenseCategory)] = [
            ("market", .groceries),
            ("coffee", .dining), ("cafe", .dining),
            ("uber", .transport), ("lyft", .transport), ("taxi", .transport),
            ("air", .travel), ("hotel", .travel)
        ]
        for (keyword, category) in rules where name.contains(keyword) {
            return category
        }
        return .other
    }

    /// The scripted model's answers. Four are wrong on purpose: two with low
    /// confidence (Sweetgreen, Amazon) and two with high (Uber Eats, Apple Store).
    static let modelAnswers: [String: Decision<ExpenseCategory>] = [
        "Whole Foods Market": Decision(value: .groceries, confidence: 0.95),
        "Trader Joe's": Decision(value: .groceries, confidence: 0.93),
        "Safeway": Decision(value: .groceries, confidence: 0.91),
        "Blue Bottle Coffee": Decision(value: .dining, confidence: 0.94),
        "Chipotle": Decision(value: .dining, confidence: 0.92),
        "Sweetgreen": Decision(value: .groceries, confidence: 0.62),
        "Uber Trip": Decision(value: .transport, confidence: 0.97),
        "Lyft Ride": Decision(value: .transport, confidence: 0.96),
        "Uber Eats": Decision(value: .transport, confidence: 0.81),
        "Shell Oil": Decision(value: .transport, confidence: 0.88),
        "Delta Air Lines": Decision(value: .travel, confidence: 0.96),
        "Marriott Hotels": Decision(value: .travel, confidence: 0.95),
        "Airbnb": Decision(value: .travel, confidence: 0.90),
        "GitHub": Decision(value: .software, confidence: 0.97),
        "Figma": Decision(value: .software, confidence: 0.94),
        "Notion Labs": Decision(value: .software, confidence: 0.89),
        "PG&E": Decision(value: .utilities, confidence: 0.92),
        "Comcast Xfinity": Decision(value: .utilities, confidence: 0.86),
        "Verizon Wireless": Decision(value: .utilities, confidence: 0.90),
        "Amazon": Decision(value: .software, confidence: 0.58),
        "Costco Wholesale": Decision(value: .groceries, confidence: 0.74),
        "Apple Store": Decision(value: .software, confidence: 0.77),
        "Starbucks": Decision(value: .dining, confidence: 0.96)
    ]

    /// 24 labelled merchants. The last one is unknown to the model.
    public static let golden: [GoldenCase<String, ExpenseCategory>] = [
        GoldenCase("Whole Foods Market", expected: .groceries),
        GoldenCase("Trader Joe's", expected: .groceries),
        GoldenCase("Safeway", expected: .groceries),
        GoldenCase("Blue Bottle Coffee", expected: .dining),
        GoldenCase("Chipotle", expected: .dining),
        GoldenCase("Sweetgreen", expected: .dining),
        GoldenCase("Uber Trip", expected: .transport),
        GoldenCase("Lyft Ride", expected: .transport),
        GoldenCase("Uber Eats", expected: .dining),
        GoldenCase("Shell Oil", expected: .transport),
        GoldenCase("Delta Air Lines", expected: .travel),
        GoldenCase("Marriott Hotels", expected: .travel),
        GoldenCase("Airbnb", expected: .travel),
        GoldenCase("GitHub", expected: .software),
        GoldenCase("Figma", expected: .software),
        GoldenCase("Notion Labs", expected: .software),
        GoldenCase("PG&E", expected: .utilities),
        GoldenCase("Comcast Xfinity", expected: .utilities),
        GoldenCase("Verizon Wireless", expected: .utilities),
        GoldenCase("Amazon", expected: .other),
        GoldenCase("Costco Wholesale", expected: .groceries),
        GoldenCase("Apple Store", expected: .other),
        GoldenCase("Starbucks", expected: .dining),
        GoldenCase("Unknown Merchant 4471", expected: .other)
    ]

    public static let silentGate = EvalGate(minMarginOverFallback: 0.10, maxSilentErrorRate: 0.05)

    /// Preselects a category on the "new expense" sheet. The user sees it and can change it.
    public static func categoryDefault(minConfidence: Double = 0.80) -> FailureModeContract<String, ExpenseCategory> {
        FailureModeContract(
            feature: "Category default",
            interaction: .tap,
            budget: .milliseconds(250),
            role: .suggestion,
            minConfidence: minConfidence,
            evalGate: silentGate,
            fallback: { SampleExpenses.keywordRule($0) }
        )
    }

    /// Files receipts into a category in the background, with a 10-second undo toast.
    public static let autoFile = FailureModeContract<String, ExpenseCategory>(
        feature: "Auto-file receipt",
        interaction: .background,
        budget: .seconds(2),
        role: .action(.undoable(window: .seconds(10))),
        minConfidence: 0.90,
        evalGate: silentGate,
        fallback: { _ in .other }
    )

    /// The feature a PM asks for in week one. It fails four rules.
    public static let autoApprove = FailureModeContract<String, Bool>(
        feature: "Auto-approve reimbursement",
        interaction: .submit,
        budget: .milliseconds(1_500),
        role: .action(.irreversible),
        minConfidence: 0.0,
        evalGate: nil,
        fallback: { _ in false }
    )

    public static var allSummaries: [ContractSummary] {
        [categoryDefault().summary, autoFile.summary, autoApprove.summary]
    }
}
