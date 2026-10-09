import XCTest
@testable import InvisibleAI

final class ResolveTests: XCTestCase {
    func testHealthyModelAnswersInsideBudget() async {
        let contract = SampleExpenses.categoryDefault()
        let result = await contract.resolve("Whole Foods Market", using: ScriptedMerchantClassifier(condition: .healthy))
        XCTAssertEqual(result.value, .groceries)
        XCTAssertEqual(result.source, .model(confidence: 0.95))
    }

    func testNoModelUsesFallback() async {
        let contract = SampleExpenses.categoryDefault()
        let result = await contract.resolve("Lyft Ride", using: ScriptedMerchantClassifier?.none)
        XCTAssertEqual(result.value, .transport)
        XCTAssertEqual(result.source, .fallback(.unavailable))
    }

    func testOfflineModelUsesFallback() async {
        let contract = SampleExpenses.categoryDefault()
        let result = await contract.resolve("Blue Bottle Coffee", using: ScriptedMerchantClassifier(condition: .offline))
        XCTAssertEqual(result.value, .dining)
        XCTAssertEqual(result.source, .fallback(.unavailable))
    }

    func testSlowModelLosesToBudget() async {
        let contract = SampleExpenses.categoryDefault()
        let result = await contract.resolve("GitHub", using: ScriptedMerchantClassifier(condition: .slow))
        XCTAssertEqual(result.source, .fallback(.overBudget))
        XCTAssertEqual(result.value, .other)
        XCTAssertLessThan(result.elapsed, .milliseconds(550))
    }

    func testLowConfidenceAnswerIsDiscarded() async {
        let contract = SampleExpenses.categoryDefault(minConfidence: 0.80)
        // Model says groceries at 0.62; the rule has no keyword, so .other.
        let result = await contract.resolve("Sweetgreen", using: ScriptedMerchantClassifier(condition: .healthy))
        XCTAssertEqual(result.source, .fallback(.lowConfidence))
        XCTAssertEqual(result.value, .other)
    }

    /// The edge case that motivated FirstWins: a model that ignores
    /// cancellation must not hold the caller past the budget.
    func testStuckModelStillRespectsBudget() async {
        let contract = SampleExpenses.categoryDefault()
        let result = await contract.resolve("Figma", using: ScriptedMerchantClassifier(condition: .stuck))
        XCTAssertEqual(result.source, .fallback(.overBudget))
        XCTAssertLessThan(result.elapsed, .milliseconds(1_000), "the 1.5 s model held the caller")
    }

    /// The obvious implementation, kept here as evidence. A task group waits
    /// for every child, so the stuck model holds it for the full 1.5 s even
    /// though the timer "won" at 250 ms.
    func testNaiveTaskGroupRaceWaitsForStuckModel() async {
        let model = ScriptedMerchantClassifier(condition: .stuck)
        let clock = ContinuousClock()
        let start = clock.now
        let winner: String = await withTaskGroup(of: String.self) { group in
            group.addTask { (try? await model.decide("Figma")) == nil ? "failed" : "model" }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return "timer"
            }
            let first = await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        let elapsed = clock.now - start
        XCTAssertEqual(winner, "timer")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1_400))
    }
}

final class LinterTests: XCTestCase {
    func testShippableContractsAreClean() {
        XCTAssertEqual(ContractLinter.audit(SampleExpenses.categoryDefault().summary), [])
        XCTAssertEqual(ContractLinter.audit(SampleExpenses.autoFile.summary), [])
    }

    func testAutoApproveFailsFourRules() {
        let findings = ContractLinter.audit(SampleExpenses.autoApprove.summary)
        XCTAssertEqual(Set(findings.map(\.rule)), [.irreversibleAction, .actionWithoutConfidenceFloor, .missingEvalGate, .budgetOverInteractionCeiling])
        XCTAssertEqual(findings.filter { $0.severity == .error }.count, 3)
        XCTAssertEqual(findings.last?.severity, .warning, "errors sort before warnings")
    }

    func testZeroMarginGateAndBadConfidenceAreFlagged() {
        let summary = ContractSummary(
            feature: "x", interaction: .keystroke, budget: .milliseconds(50), role: .suggestion,
            minConfidence: 1.2, evalGate: EvalGate(minMarginOverFallback: 0, maxSilentErrorRate: 0.05)
        )
        XCTAssertEqual(Set(ContractLinter.audit(summary).map(\.rule)), [.confidenceOutOfRange, .nonPositiveMargin])
    }

    func testBudgetExactlyAtCeilingIsAllowed() {
        let summary = ContractSummary(
            feature: "x", interaction: .tap, budget: Interaction.tap.ceiling, role: .suggestion,
            minConfidence: 0.8, evalGate: SampleExpenses.silentGate
        )
        XCTAssertEqual(ContractLinter.audit(summary), [])
    }
}

final class EvalTests: XCTestCase {
    func testThresholdPointSevenFailsTheSilentErrorGate() async {
        let report = await SampleExpenses.categoryDefault(minConfidence: 0.70)
            .evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier())
        XCTAssertEqual(report.cases, 24)
        XCTAssertEqual(report.modelCorrect, 20)
        XCTAssertEqual(report.fallbackCorrect, 10)
        XCTAssertEqual(report.contractCorrect, 21)
        XCTAssertEqual(report.confident, 21)
        XCTAssertEqual(report.silentErrors, 2)
        XCTAssertFalse(report.passes(SampleExpenses.silentGate))
        XCTAssertEqual(report.failures(against: SampleExpenses.silentGate).count, 1)
    }

    func testThresholdPointEightPassesWithSameAccuracy() async {
        let report = await SampleExpenses.categoryDefault(minConfidence: 0.80)
            .evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier())
        XCTAssertEqual(report.contractCorrect, 21)
        XCTAssertEqual(report.confident, 19)
        XCTAssertEqual(report.silentErrors, 1)
        XCTAssertTrue(report.passes(SampleExpenses.silentGate))
    }

    func testOverconfidentModelFailsTheGate() async {
        let report = await SampleExpenses.categoryDefault(minConfidence: 0.80)
            .evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier(condition: .overconfident))
        XCTAssertEqual(report.confident, 24)
        XCTAssertEqual(report.silentErrors, 4)
        XCTAssertEqual(report.contractCorrect, 20)
        XCTAssertFalse(report.passes(SampleExpenses.silentGate))
    }

    func testOfflineModelScoresAsFallback() async {
        let report = await SampleExpenses.categoryDefault()
            .evaluate(SampleExpenses.golden, using: ScriptedMerchantClassifier(condition: .offline))
        XCTAssertEqual(report.modelCorrect, 0)
        XCTAssertEqual(report.contractCorrect, report.fallbackCorrect)
        XCTAssertFalse(report.passes(SampleExpenses.silentGate), "zero margin over the fallback")
    }

    func testEmptyGoldenSetNeverPasses() async {
        let report = await SampleExpenses.categoryDefault().evaluate([], using: ScriptedMerchantClassifier())
        XCTAssertEqual(report.coverage, 0)
        XCTAssertFalse(report.passes(SampleExpenses.silentGate))
    }

    func testPercentFormatting() {
        XCTAssertEqual(pct(0.875), "87.5%")
        XCTAssertEqual(pct(1.0 / 24.0), "4.2%")
        XCTAssertEqual(pct(-0.05), "-5.0%")
    }
}

final class SurfaceTests: XCTestCase {
    func testBoundedAnswerIsEmbedded() {
        let r = SurfaceRubric.recommend(SurfaceQuestions(answerSpaceIsBounded: true, userKnowsWhatToAsk: true, needsBackAndForth: true))
        XCTAssertEqual(r.surface, .embedded)
    }

    func testChatOnlyWhenAllThreeHold() {
        XCTAssertEqual(SurfaceRubric.recommend(SurfaceQuestions(answerSpaceIsBounded: false, userKnowsWhatToAsk: true, needsBackAndForth: true)).surface, .chat)
        XCTAssertEqual(SurfaceRubric.recommend(SurfaceQuestions(answerSpaceIsBounded: false, userKnowsWhatToAsk: false, needsBackAndForth: true)).surface, .embedded)
        XCTAssertEqual(SurfaceRubric.recommend(SurfaceQuestions(answerSpaceIsBounded: false, userKnowsWhatToAsk: true, needsBackAndForth: false)).surface, .embedded)
    }
}
