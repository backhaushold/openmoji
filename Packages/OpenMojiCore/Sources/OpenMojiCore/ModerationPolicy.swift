import Foundation

/// One moderation verdict from `POST /v1/moderations`: `results[0]`, reduced
/// to the fields the policy reads (tech spec §5.5, ADR-0019).
///
/// Keys are OpenAI's category names (`violence/graphic`, `self-harm`, ...).
/// `category_applied_input_types` is not kept: a category that does not apply
/// to the input type (for example `sexual/minors` on an image) scores 0, so a
/// limit on it can never trip.
public struct ModerationResult: Equatable, Sendable {
    /// OpenAI's own "any category flagged" verdict.
    public let flagged: Bool
    /// Per-category flags. A `null` flag in the response is left out.
    public let categories: [String: Bool]
    /// Per-category scores, 0 to 1.
    public let categoryScores: [String: Double]

    public init(flagged: Bool, categories: [String: Bool], categoryScores: [String: Double]) {
        self.flagged = flagged
        self.categories = categories
        self.categoryScores = categoryScores
    }
}

/// What the app does with a `ModerationResult`.
public enum ModerationDecision: Equatable, Sendable {
    case allow
    /// `reasons` are the category names that tripped the policy. They are for
    /// the log only: the child sees `GenerationError.contentRefused`'s copy,
    /// never a category.
    case block(reasons: [String])
}

/// The blocking policy of ADR-0019: pure and free of networking, so every
/// threshold is covered by a unit test and the whole policy is in this file.
///
/// A result is blocked when any of these holds:
/// 1. OpenAI's `flagged` is true, or any category flag is true (any category,
///    including plain `violence`, `hate` and `harassment`).
/// 2. A score reaches its limit in `scoreLimits`: graphic violence, sexual
///    content (`sexual/minors` stricter) and the self-harm family. These sit
///    below OpenAI's own flag cut-off on purpose ("strict on gore and sex").
///
/// Plain `violence` has no score limit, only OpenAI's flag, so a water gun or
/// a knight with a sword still passes.
///
/// **The limits are untuned first guesses.** OpenAI does not publish its flag
/// cut-offs, and says category scores "may need recalibration over time" as
/// the model is upgraded. The user-run re-check (spikes/m2-safety) is what
/// tunes them. Change a number here, nowhere else, and update ADR-0019.
public enum ModerationPolicy {
    // MARK: Limits (untuned, ADR-0019)

    /// `violence/graphic`. OpenAI's own docs example (a war-movie frame) scores
    /// 0.377 here and is not flagged for this category, so 0.10 is clearly
    /// stricter than the flag.
    static let graphicViolenceLimit = 0.10
    /// `sexual`.
    static let sexualLimit = 0.10
    /// `sexual/minors`: text only. Stricter, because any appreciable score for
    /// sexual content involving a minor is unacceptable in a children's app.
    static let sexualMinorsLimit = 0.05
    /// `self-harm`, `self-harm/intent` and `self-harm/instructions`.
    static let selfHarmLimit = 0.10

    /// Every category with a score limit, in the order reasons are reported. A
    /// score at or above its limit blocks.
    static let scoreLimits: [(category: String, limit: Double)] = [
        ("violence/graphic", graphicViolenceLimit),
        ("sexual", sexualLimit),
        ("sexual/minors", sexualMinorsLimit),
        ("self-harm", selfHarmLimit),
        ("self-harm/intent", selfHarmLimit),
        ("self-harm/instructions", selfHarmLimit),
    ]

    // MARK: Decision

    public static func decide(_ result: ModerationResult) -> ModerationDecision {
        var reasons = result.categories.filter(\.value).keys.sorted()
        for (category, limit) in scoreLimits {
            let score = result.categoryScores[category] ?? 0
            if score >= limit, !reasons.contains(category) { reasons.append(category) }
        }
        // `flagged` with no category named: still blocked.
        if reasons.isEmpty, result.flagged { reasons = ["flagged"] }
        return reasons.isEmpty ? .allow : .block(reasons: reasons)
    }
}
