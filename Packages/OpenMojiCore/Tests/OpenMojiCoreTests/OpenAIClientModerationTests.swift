import Foundation
import Testing
@testable import OpenMojiCore

/// `OpenAIClient.moderate(text:)` and `moderate(imagePNG:)` against a
/// `URLProtocol` stub (tech spec §5.5, ADR-0019): the request shape, the
/// decoded verdict, and that every failure is a `GenerationError` (fail
/// closed). Each test gets its own stub state, as in `OpenAIClientTests`.
@Suite(.serialized) struct OpenAIClientModerationTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private let apiKey = "test-fake-key-0000"

    private let stub = StubURLProtocol.Stub()

    private func makeClient() -> OpenAIClient {
        stub.makeClient()
    }

    private func onlyRecorded() throws -> (request: URLRequest, json: [String: Any]) {
        let recorded = stub.recorded
        try #require(recorded.count == 1)
        let json = try #require(ModerationFixture.json(recorded[0]))
        return (recorded[0].request, json)
    }

    private func errorBody(message: String = "msg", type: String? = nil, code: String? = nil) -> Data {
        func json(_ s: String?) -> Any { s ?? NSNull() }
        let object: [String: Any] = [
            "error": ["message": message, "type": json(type), "code": json(code), "param": NSNull()],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Request (text)

    @Test func postsTextToTheModerationsEndpointWithTheKey() async throws {
        stub.reset(ModerationFixture.clean)
        _ = try await makeClient().moderate(text: "a happy cat", apiKey: apiKey)

        let (request, _) = try onlyRecorded()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/moderations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 90)
    }

    @Test func textBodyIsTheModelAndABareString() async throws {
        stub.reset(ModerationFixture.clean)
        let text = "a \"quoted\" cat\nwith a \\ backslash \u{1F431}"
        _ = try await makeClient().moderate(text: text, apiKey: apiKey)

        let (_, json) = try onlyRecorded()
        #expect(json["model"] as? String == "omni-moderation-latest")
        #expect(json["input"] as? String == text)
        #expect(Set(json.keys) == ["model", "input"])
    }

    // MARK: Request (image)

    @Test func imageBodyIsOneImageURLPartWithABase64PNGDataURL() async throws {
        stub.reset(ModerationFixture.clean)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        _ = try await makeClient().moderate(imagePNG: png, apiKey: apiKey)

        let (request, json) = try onlyRecorded()
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/moderations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(json["model"] as? String == "omni-moderation-latest")
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "image_url")
        let imageURL = try #require(input[0]["image_url"] as? [String: Any])
        #expect(imageURL["url"] as? String == "data:image/png;base64," + png.base64EncodedString())
        #expect(Set(input[0].keys) == ["type", "image_url"])
    }

    // MARK: Response

    @Test func decodesTheVerdict() async throws {
        let body = ModerationFixture.body(
            flagged: true,
            flags: ["violence": true],
            scores: ["violence": 0.86, "violence/graphic": 0.377]
        )
        stub.reset(.respond(status: 200, body: body))

        let result = try await makeClient().moderate(text: "knight", apiKey: apiKey)

        #expect(result.flagged)
        #expect(result.categories["violence"] == true)
        #expect(result.categories["hate"] == false)
        #expect(result.categories.count == ModerationFixture.categories.count)
        #expect(result.categoryScores["violence"] == 0.86)
        #expect(result.categoryScores["violence/graphic"] == 0.377)
        #expect(result.categoryScores.count == ModerationFixture.categories.count)
    }

    @Test func nullCategoryFlagsAreDroppedAndUnknownCategoriesKept() async throws {
        let body = Data("""
            {"results": [{"flagged": false,
              "categories": {"illicit": null, "violence": false, "future/category": true},
              "category_scores": {"illicit": null, "violence": 0.2, "future/category": 0.7}}]}
            """.utf8)
        stub.reset(.respond(status: 200, body: body))

        let result = try await makeClient().moderate(text: "x", apiKey: apiKey)

        #expect(result.categories == ["violence": false, "future/category": true])
        #expect(result.categoryScores == ["violence": 0.2, "future/category": 0.7])
    }

    @Test func extraFieldsAndASecondResultAreIgnored() async throws {
        let body = Data("""
            {"id": "x", "model": "m", "extra": 1, "results": [
              {"flagged": true, "categories": {"hate": true}, "category_scores": {"hate": 0.9}, "other": []},
              {"flagged": false, "categories": {}, "category_scores": {}}]}
            """.utf8)
        stub.reset(.respond(status: 200, body: body))

        let result = try await makeClient().moderate(text: "x", apiKey: apiKey)

        #expect(result == ModerationResult(flagged: true, categories: ["hate": true], categoryScores: ["hate": 0.9]))
    }

    /// A 200 with no usable verdict is a failure, never an implicit "fine".
    @Test(arguments: [
        ("no results", Data(#"{"id": "x"}"#.utf8)),
        ("empty results", Data(#"{"results": []}"#.utf8)),
        ("null results", Data(#"{"results": null}"#.utf8)),
        ("missing flagged", Data(#"{"results": [{"categories": {}, "category_scores": {}}]}"#.utf8)),
        ("non-boolean flagged", Data(#"{"results": [{"flagged": "yes", "categories": {}, "category_scores": {}}]}"#.utf8)),
        ("missing categories", Data(#"{"results": [{"flagged": false, "category_scores": {}}]}"#.utf8)),
        ("missing scores", Data(#"{"results": [{"flagged": false, "categories": {}}]}"#.utf8)),
        ("malformed scores", Data(#"{"results": [{"flagged": false, "categories": {}, "category_scores": {"a": "high"}}]}"#.utf8)),
        ("not JSON", Data("<html>gateway</html>".utf8)),
        ("empty body", Data()),
    ])
    func aSuccessWithoutAVerdictIsServiceUnavailable(label: String, body: Data) async {
        stub.reset(.respond(status: 200, body: body))

        await #expect(throws: GenerationError.serviceUnavailable, "\(label)") {
            try await makeClient().moderate(text: "x", apiKey: apiKey)
        }
        await #expect(throws: GenerationError.serviceUnavailable, "\(label) (image)") {
            try await makeClient().moderate(imagePNG: Data([1, 2, 3]), apiKey: apiKey)
        }
    }

    // MARK: Failures (fail closed)

    @Test(arguments: [
        (401, [:], "invalid_api_key", "invalid_request_error", GenerationError.invalidKey),
        (429, ["Retry-After": "7"], "rate_limit_exceeded", "requests", .rateLimited(retryAfter: 7)),
        (500, [:], "server_error", "server_error", .serviceUnavailable),
        (503, [:], "server_is_overloaded", "server_error", .serviceUnavailable),
    ] as [(Int, [String: String], String, String, GenerationError)])
    func httpFailureMapsThroughTheErrorMapper(
        status: Int, headers: [String: String], code: String, type: String, expected: GenerationError
    ) async {
        stub.reset(.respond(status: status, headers: headers, body: errorBody(type: type, code: code)))

        await #expect(throws: expected) { try await makeClient().moderate(text: "x", apiKey: apiKey) }
        await #expect(throws: expected) { try await makeClient().moderate(imagePNG: Data([1]), apiKey: apiKey) }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, GenerationError.offline),
        (.timedOut, .timeout),
        (.cannotFindHost, .serviceUnavailable),
    ])
    func transportFailureMapsThroughTheErrorMapper(code: URLError.Code, expected: GenerationError) async {
        stub.reset(.fail(code))

        await #expect(throws: expected) { try await makeClient().moderate(text: "x", apiKey: apiKey) }
    }

    @Test func aFailureIsNotRetried() async {
        stub.reset(.respond(status: 500, body: errorBody(code: "server_error")))

        _ = try? await makeClient().moderate(text: "x", apiKey: apiKey)

        #expect(stub.recorded.count == 1)
    }

    @Test func noFailureMentionsTheKey() async {
        let leaky = errorBody(message: "Incorrect API key provided: sk-proj-abcdef****wxyz", code: "invalid_api_key")
        stub.reset(.respond(status: 401, body: leaky))

        do {
            _ = try await makeClient().moderate(text: "x", apiKey: apiKey)
            Issue.record("expected a failure")
        } catch {
            for text in ["\(error)", String(reflecting: error), error.userMessage ?? ""] {
                #expect(!text.contains(apiKey) && !text.contains("sk-"), "\(text)")
            }
        }
    }

    // MARK: Cancellation

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        stub.reset(.hang)
        let client = makeClient()
        let key = apiKey
        let task = Task { try await client.moderate(text: "x", apiKey: key) }

        try await waitUntil { stub.recorded.count == 1 }
        task.cancel()

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        try await waitUntil { stub.stopLoadingCount >= 1 }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out waiting for condition")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
