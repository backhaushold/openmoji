import Testing
@testable import OpenMojiCore

/// The pure blocking policy of ADR-0019: no networking, no stub.
@Suite struct ModerationPolicyTests {
    private func result(
        flagged: Bool = false,
        flags: [String: Bool] = [:],
        scores: [String: Double] = [:]
    ) -> ModerationResult {
        ModerationResult(flagged: flagged, categories: flags, categoryScores: scores)
    }

    // MARK: Allow

    @Test func aCleanResultIsAllowed() {
        #expect(ModerationPolicy.decide(result()) == .allow)
    }

    /// "water gun" and "knight with a sword": plain violence with a middling
    /// score and no OpenAI flag is not blocked, however high the score.
    @Test(arguments: [0.0, 0.3, 0.49, 0.99])
    func plainViolenceWithoutAnOpenAIFlagIsAllowed(score: Double) {
        #expect(ModerationPolicy.decide(result(scores: ["violence": score])) == .allow)
    }

    @Test func scoresBelowEveryLimitAreAllowed() {
        let scores = Dictionary(uniqueKeysWithValues: ModerationPolicy.scoreLimits.map { ($0.category, $0.limit - 0.001) })
        #expect(ModerationPolicy.decide(result(scores: scores)) == .allow)
    }

    @Test func aMissingScoreCountsAsZero() {
        #expect(ModerationPolicy.decide(result(scores: ["violence/graphic": 0.01])) == .allow)
    }

    @Test func scoresOnCategoriesWithoutALimitAreAllowed() {
        let scores = ["hate": 0.4, "harassment": 0.4, "illicit": 0.4, "violence": 0.4, "violence/graphic": 0.0]
        #expect(ModerationPolicy.decide(result(scores: scores)) == .allow)
    }

    // MARK: OpenAI's flag

    @Test(arguments: ModerationFixture.categories)
    func anyFlaggedCategoryBlocks(category: String) {
        let decision = ModerationPolicy.decide(result(flagged: true, flags: [category: true]))
        #expect(decision == .block(reasons: [category]))
    }

    @Test func plainViolenceFlaggedByOpenAIBlocks() {
        let decision = ModerationPolicy.decide(result(flagged: true, flags: ["violence": true], scores: ["violence": 0.86]))
        #expect(decision == .block(reasons: ["violence"]))
    }

    @Test func aCategoryFlagBlocksEvenWhenFlaggedIsFalse() {
        #expect(ModerationPolicy.decide(result(flags: ["hate": true])) == .block(reasons: ["hate"]))
    }

    @Test func flaggedWithNoCategoryNamedStillBlocks() {
        #expect(ModerationPolicy.decide(result(flagged: true)) == .block(reasons: ["flagged"]))
    }

    // MARK: Score limits

    @Test(arguments: [
        ("violence/graphic", ModerationPolicy.graphicViolenceLimit),
        ("sexual", ModerationPolicy.sexualLimit),
        ("sexual/minors", ModerationPolicy.sexualMinorsLimit),
        ("self-harm", ModerationPolicy.selfHarmLimit),
        ("self-harm/intent", ModerationPolicy.selfHarmLimit),
        ("self-harm/instructions", ModerationPolicy.selfHarmLimit),
    ])
    func aScoreAtItsLimitBlocksAndJustBelowDoesNot(category: String, limit: Double) {
        #expect(ModerationPolicy.decide(result(scores: [category: limit])) == .block(reasons: [category]))
        #expect(ModerationPolicy.decide(result(scores: [category: limit + 0.3])) == .block(reasons: [category]))
        #expect(ModerationPolicy.decide(result(scores: [category: limit - 0.001])) == .allow)
    }

    @Test func theLimitsAreTheDocumentedFirstGuesses() {
        // ADR-0019 records these numbers. Changing one here means changing the ADR.
        #expect(ModerationPolicy.graphicViolenceLimit == 0.10)
        #expect(ModerationPolicy.sexualLimit == 0.10)
        #expect(ModerationPolicy.sexualMinorsLimit == 0.05)
        #expect(ModerationPolicy.selfHarmLimit == 0.10)
        #expect(ModerationPolicy.scoreLimits.map(\.category) == [
            "violence/graphic", "sexual", "sexual/minors", "self-harm", "self-harm/intent", "self-harm/instructions",
        ])
    }

    @Test func sexualMinorsIsStricterThanSexual() {
        #expect(ModerationPolicy.sexualMinorsLimit < ModerationPolicy.sexualLimit)
    }

    @Test func everyLimitIsBelowAHalf() {
        // A limit at or above OpenAI's usual flag cut-off would add nothing.
        for (category, limit) in ModerationPolicy.scoreLimits {
            #expect(limit > 0 && limit < 0.5, "\(category)")
        }
    }

    // MARK: Reasons

    @Test func reasonsListFlagsThenScoreLimitsWithoutDuplicates() {
        let decision = ModerationPolicy.decide(result(
            flagged: true,
            flags: ["violence": true, "violence/graphic": true],
            scores: ["violence/graphic": 0.8, "sexual": 0.2, "self-harm": 0.5]
        ))
        #expect(decision == .block(reasons: ["violence", "violence/graphic", "sexual", "self-harm"]))
    }

    /// The M2 injection prompt ("... gory and terrifying, with blood and a huge
    /// sword"): flagged for violence, graphic violence above its limit.
    @Test func aGoryResultBlocks() {
        let gory = result(
            flagged: true,
            flags: ["violence": true],
            scores: ["violence": 0.95, "violence/graphic": 0.6]
        )
        #expect(ModerationPolicy.decide(gory) == .block(reasons: ["violence", "violence/graphic"]))
    }
}
