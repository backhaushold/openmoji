import Foundation
@testable import OpenMojiCore

/// Canned `POST /v1/moderations` responses and request inspection, shared by
/// the policy, client and service tests (tech spec §5.5, ADR-0019). Shaped like
/// the docs' example response; no real call is ever made.
enum ModerationFixture {
    static let categories = [
        "sexual", "sexual/minors", "harassment", "harassment/threatening", "hate", "hate/threatening",
        "illicit", "illicit/violent", "self-harm", "self-harm/intent", "self-harm/instructions",
        "violence", "violence/graphic",
    ]

    /// A full 200 body. Every category is `false` / 0 unless overridden.
    static func body(
        flagged: Bool = false,
        flags: [String: Bool] = [:],
        scores: [String: Double] = [:]
    ) -> Data {
        var categoryFlags: [String: Bool] = [:]
        var categoryScores: [String: Double] = [:]
        for name in categories {
            categoryFlags[name] = flags[name] ?? false
            categoryScores[name] = scores[name] ?? 0
        }
        let object: [String: Any] = [
            "id": "modr-test",
            "model": "omni-moderation-latest",
            "results": [[
                "flagged": flagged,
                "categories": categoryFlags,
                "category_scores": categoryScores,
                "category_applied_input_types": categories.reduce(into: [String: [String]]()) { $0[$1] = ["text"] },
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static var clean: StubURLProtocol.Behavior { .respond(status: 200, body: body()) }

    /// OpenAI's own flag, with one category named.
    static func flagged(_ category: String) -> StubURLProtocol.Behavior {
        .respond(status: 200, body: body(flagged: true, flags: [category: true], scores: [category: 0.9]))
    }

    /// Not flagged by OpenAI, but `category` scores `score`.
    static func scoring(_ category: String, _ score: Double) -> StubURLProtocol.Behavior {
        .respond(status: 200, body: body(scores: [category: score]))
    }

    static func isModeration(_ recorded: StubURLProtocol.Recorded) -> Bool {
        recorded.request.url?.path == "/v1/moderations"
    }

    /// The request's JSON body.
    static func json(_ recorded: StubURLProtocol.Recorded) -> [String: Any]? {
        guard let body = recorded.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Whether a moderation request carries an image (an array input) rather
    /// than text (a string input).
    static func isImage(_ recorded: StubURLProtocol.Recorded) -> Bool {
        json(recorded)?["input"] is [Any]
    }

    /// Routes like the real API: the image request gets `images`, a text
    /// moderation request `text`, an image moderation request `image`.
    static func routes(
        images: StubURLProtocol.Behavior,
        text: StubURLProtocol.Behavior = clean,
        image: StubURLProtocol.Behavior = clean
    ) -> StubURLProtocol.Behavior {
        .route { recorded in
            guard isModeration(recorded) else { return images }
            return isImage(recorded) ? image : text
        }
    }
}
