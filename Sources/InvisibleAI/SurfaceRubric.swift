/// When is a chat box actually the right surface for an AI feature?
public struct SurfaceQuestions: Sendable, Equatable {
    /// The answer fits a Bool, an enum or a score.
    public var answerSpaceIsBounded: Bool
    /// The user can say what they want in words without being taught.
    public var userKnowsWhatToAsk: Bool
    /// Getting to a good answer usually takes more than one round.
    public var needsBackAndForth: Bool

    public init(answerSpaceIsBounded: Bool, userKnowsWhatToAsk: Bool, needsBackAndForth: Bool) {
        self.answerSpaceIsBounded = answerSpaceIsBounded
        self.userKnowsWhatToAsk = userKnowsWhatToAsk
        self.needsBackAndForth = needsBackAndForth
    }
}

public enum Surface: String, Sendable, Equatable {
    /// AI as a property of an existing control: a default, a ranking, a button.
    case embedded
    /// A conversational surface.
    case chat
}

public struct SurfaceRecommendation: Sendable, Equatable {
    public var surface: Surface
    public var reason: String
}

public enum SurfaceRubric {
    /// Chat earns its place only when all three hold: the answer space is
    /// open, the user knows what to ask, and the answer takes iteration.
    public static func recommend(_ q: SurfaceQuestions) -> SurfaceRecommendation {
        if q.answerSpaceIsBounded {
            return SurfaceRecommendation(surface: .embedded, reason: "The answer is a Bool, enum or score. Put it in the control that already exists.")
        }
        if !q.userKnowsWhatToAsk {
            return SurfaceRecommendation(surface: .embedded, reason: "An empty text box asks users to invent the feature. Enhance an interface they already understand.")
        }
        if !q.needsBackAndForth {
            return SurfaceRecommendation(surface: .embedded, reason: "One question, one answer: a search field or a button does this without a transcript.")
        }
        return SurfaceRecommendation(surface: .chat, reason: "Open answer space, a user who knows what to ask, and real iteration. This is what chat is for.")
    }
}
