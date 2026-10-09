import Foundation

/// A typed, single-pass answer from a model: a value plus how sure it is.
public struct Decision<Output: Sendable>: Sendable {
    public var value: Output
    /// 0.0 ... 1.0
    public var confidence: Double

    public init(value: Output, confidence: Double) {
        self.value = value
        self.confidence = confidence
    }
}

/// Anything that turns an input into a typed decision: an on-device
/// Foundation Models session, a System One classifier, a cloud call.
public protocol DecisionModel<Input, Output>: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func decide(_ input: Input) async throws -> Decision<Output>
}

public enum FallbackReason: String, Sendable, Equatable {
    /// No model, or the model threw.
    case unavailable
    /// The model did not answer inside the interaction's budget.
    case overBudget
    /// The model answered below the contract's confidence floor.
    case lowConfidence
}

public enum ResolutionSource: Sendable, Equatable {
    case model(confidence: Double)
    case fallback(FallbackReason)

    public var usedModel: Bool {
        if case .model = self { return true }
        return false
    }
}

public struct Resolution<Output: Sendable>: Sendable {
    public var value: Output
    public var source: ResolutionSource
    public var elapsed: Duration
}

extension FailureModeContract {
    /// Resolves one input under the contract.
    ///
    /// The model races the budget. The race is built on a continuation that
    /// resumes exactly once, not on a task group: a task group waits for every
    /// child before it returns, so a model that ignores cancellation would hold
    /// the caller for its full duration and the "budget" would be fiction.
    public func resolve<M: DecisionModel>(
        _ input: Input,
        using model: M?
    ) async -> Resolution<Output> where M.Input == Input, M.Output == Output {
        let clock = ContinuousClock()
        let start = clock.now

        guard let model else {
            return Resolution(value: fallback(input), source: .fallback(.unavailable), elapsed: clock.now - start)
        }

        let budget = self.budget
        let outcome: RaceOutcome<Output> = await withCheckedContinuation { continuation in
            let race = FirstWins(continuation)
            race.track(Task {
                do {
                    let decision = try await model.decide(input)
                    race.finish(.decided(decision))
                } catch {
                    race.finish(.failed)
                }
            })
            race.track(Task {
                try? await Task.sleep(for: budget)
                race.finish(.timedOut)
            })
        }

        let elapsed = clock.now - start
        switch outcome {
        case .decided(let decision) where decision.confidence >= minConfidence:
            return Resolution(value: decision.value, source: .model(confidence: decision.confidence), elapsed: elapsed)
        case .decided:
            return Resolution(value: fallback(input), source: .fallback(.lowConfidence), elapsed: elapsed)
        case .failed:
            return Resolution(value: fallback(input), source: .fallback(.unavailable), elapsed: elapsed)
        case .timedOut:
            return Resolution(value: fallback(input), source: .fallback(.overBudget), elapsed: elapsed)
        }
    }
}

enum RaceOutcome<Output: Sendable>: Sendable {
    case decided(Decision<Output>)
    case failed
    case timedOut
}

/// Resumes a continuation with the first outcome and cancels every other
/// tracked task. Later outcomes are dropped.
final class FirstWins<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RaceOutcome<Output>, Never>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<RaceOutcome<Output>, Never>) {
        self.continuation = continuation
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = continuation == nil
        if !alreadyFinished { tasks.append(task) }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ outcome: RaceOutcome<Output>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let losers = tasks
        tasks.removeAll()
        lock.unlock()
        continuation.resume(returning: outcome)
        losers.forEach { $0.cancel() }
    }
}
