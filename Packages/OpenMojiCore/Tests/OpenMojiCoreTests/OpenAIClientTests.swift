import Foundation
import Testing
@testable import OpenMojiCore

/// A real 1x1 PNG, so "decodes to PNG Data" can check the signature.
private let cannedPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

/// `OpenAIClient` against a `URLProtocol` stub: the §5.1 request, the §5.2
/// response, the §5.3 behaviour and the routing into `ErrorMapper` (§6).
/// Serialized because the stub's state is process-wide.
@Suite(.serialized) struct OpenAIClientTests {

    // A fake key on purpose: it must not look like `sk-...` (secret scanners,
    // and the hygiene tests that assert no `sk-` leaks).
    private let apiKey = "test-fake-key-0000"

    private let defaultConfig = GenerationConfig(infoDictionary: [:])

    private func makeClient(_ config: GenerationConfig? = nil) -> OpenAIClient {
        OpenAIClient(config: config ?? defaultConfig, protocolClasses: [StubURLProtocol.self])
    }

    private func successBody(_ fields: [String: Any]? = nil) -> Data {
        let object = fields ?? [
            "created": 1_790_975_701,
            "background": "transparent",
            "output_format": "png",
            "quality": "medium",
            "size": "1024x1024",
            "data": [["b64_json": cannedPNGBase64]],
            "usage": ["input_tokens": 12, "output_tokens": 1056, "total_tokens": 1068],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func errorBody(message: String = "msg", type: String? = nil, code: String? = nil) -> Data {
        func json(_ s: String?) -> Any { s ?? NSNull() }
        let object: [String: Any] = [
            "error": [
                "message": message,
                "type": json(type),
                "code": json(code),
                "param": NSNull(),
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// The single request the stub saw, with its JSON body decoded.
    private func onlyRecorded() throws -> (request: URLRequest, json: [String: Any]) {
        let recorded = StubURLProtocol.recorded
        try #require(recorded.count == 1)
        let body = try #require(recorded[0].body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (recorded[0].request, json)
    }

    // MARK: Request (§5.1)

    @Test func postsToTheImagesGenerationsEndpoint() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        _ = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)

        let (request, _) = try onlyRecorded()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
    }

    @Test func setsAuthorizationAndContentTypeHeaders() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        _ = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)

        let (request, _) = try onlyRecorded()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func sendsEveryBodyFieldFromSection51AndNothingElse() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        _ = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)

        let (_, json) = try onlyRecorded()
        #expect(json["model"] as? String == "gpt-image-2.5-flare")
        #expect(json["prompt"] as? String == "a happy cat")
        #expect(json["n"] as? Int == 1)
        #expect(json["size"] as? String == "1024x1024")
        #expect(json["quality"] as? String == "medium")
        #expect(json["background"] as? String == "transparent")
        #expect(json["output_format"] as? String == "png")
        #expect(json["moderation"] as? String == "auto")
        // Exactly the §5.1 fields: no response_format, partial_images, user.
        #expect(Set(json.keys) == [
            "model", "prompt", "n", "size", "quality", "background", "output_format", "moderation",
        ])
    }

    @Test func takesModelAndQualityFromGenerationConfig() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        let config = GenerationConfig(infoDictionary: [
            "OpenMojiImageModel": "gpt-image-test-model",
            "OpenMojiImageQuality": "high",
        ])
        _ = try await makeClient(config).generate(prompt: "a happy cat", apiKey: apiKey)

        let (_, json) = try onlyRecorded()
        #expect(json["model"] as? String == "gpt-image-test-model")
        #expect(json["quality"] as? String == "high")
    }

    @Test func encodesPromptWithQuotesNewlinesAndUnicode() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        let prompt = "a \"quoted\" cat\nwith a \\ backslash \u{1F431}"
        _ = try await makeClient().generate(prompt: prompt, apiKey: apiKey)

        let (_, json) = try onlyRecorded()
        #expect(json["prompt"] as? String == prompt)
    }

    // MARK: Session and timeouts (§5.3)

    @Test func usesEphemeralSessionWith90SecondTimeouts() {
        let configuration = makeClient().session.configuration
        #expect(configuration.timeoutIntervalForRequest == 90)
        #expect(configuration.timeoutIntervalForResource == 90)
        // Ephemeral: nothing about prompts or images reaches disk.
        #expect(configuration.urlCache?.diskCapacity == 0)
    }

    @Test func requestCarries90SecondTimeout() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        _ = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)

        let (request, _) = try onlyRecorded()
        #expect(request.timeoutInterval == 90)
    }

    // MARK: Response (§5.2)

    @Test func decodesSuccessIntoPNGData() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        let data = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)

        #expect(data == Data(base64Encoded: cannedPNGBase64))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test(arguments: [
        ("no usage", nil),
        ("null usage", "null"),
        ("malformed usage", #""lots""#),
        ("partial usage", #"{"total_tokens": 5}"#),
        ("full usage", #"{"input_tokens": 1, "output_tokens": 2, "total_tokens": 3}"#),
    ] as [(String, String?)])
    func usageIsOptional(label: String, usage: String?) async throws {
        let usageField = usage.map { #", "usage": \#($0)"# } ?? ""
        let body = Data(#"{"data": [{"b64_json": "\#(cannedPNGBase64)"}]\#(usageField)}"#.utf8)
        StubURLProtocol.reset(.respond(status: 200, body: body))
        let data = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        #expect(data == Data(base64Encoded: cannedPNGBase64), "\(label)")
    }

    @Test func ignoresExtraResponseFieldsAndUsesFirstImage() async throws {
        let fields: [String: Any] = [
            "revised_prompt": "ignored",
            "data": [["b64_json": cannedPNGBase64, "revised_prompt": "x"], ["b64_json": "AAAA"]],
        ]
        StubURLProtocol.reset(.respond(status: 200, body: successBody(fields)))
        let data = try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        #expect(data == Data(base64Encoded: cannedPNGBase64))
    }

    @Test(arguments: [
        ("missing data", Data(#"{"created": 1}"#.utf8)),
        ("null data", Data(#"{"data": null}"#.utf8)),
        ("empty data array", Data(#"{"data": []}"#.utf8)),
        ("missing b64_json", Data(#"{"data": [{"url": "https://example.com/x.png"}]}"#.utf8)),
        ("null b64_json", Data(#"{"data": [{"b64_json": null}]}"#.utf8)),
        ("non-string b64_json", Data(#"{"data": [{"b64_json": 5}]}"#.utf8)),
        ("bad base64", Data(#"{"data": [{"b64_json": "not base64!!"}]}"#.utf8)),
        ("empty base64", Data(#"{"data": [{"b64_json": ""}]}"#.utf8)),
        ("not JSON", Data("<html>gateway</html>".utf8)),
        ("empty body", Data()),
    ])
    func undecodableSuccessIsProcessingFailed(label: String, body: Data) async {
        StubURLProtocol.reset(.respond(status: 200, body: body))
        await #expect(throws: GenerationError.processingFailed, "\(label)") {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }
    }

    // MARK: Errors (§6)

    @Test(arguments: [
        (401, [:], "invalid_api_key", "invalid_request_error"),
        (403, [:], nil, nil),
        (404, [:], "model_not_found", "invalid_request_error"),
        (429, ["Retry-After": "7"], "rate_limit_exceeded", "requests"),
        (429, [:], "insufficient_quota", "insufficient_quota"),
        (400, [:], "moderation_blocked", "image_generation_user_error"),
        (400, [:], "invalid_value", "invalid_request_error"),
        (500, [:], "server_error", "server_error"),
        (503, [:], "server_is_overloaded", "server_error"),
    ] as [(Int, [String: String], String?, String?)])
    func errorStatusIsRoutedThroughErrorMapper(
        status: Int, headers: [String: String], code: String?, type: String?
    ) async {
        let body = errorBody(message: "the api message", type: type, code: code)
        StubURLProtocol.reset(.respond(status: status, headers: headers, body: body))

        let expected = ErrorMapper.map(status: status, headers: headers, body: body)
        await #expect(throws: expected) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }
    }

    @Test func mapsSpecificStatusesToTheirGenerationErrors() async {
        StubURLProtocol.reset(.respond(status: 401, body: errorBody(code: "invalid_api_key")))
        await #expect(throws: GenerationError.invalidKey) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }

        // Retry-After reaches the mapper through the response headers.
        StubURLProtocol.reset(.respond(
            status: 429, headers: ["Retry-After": "7"], body: errorBody(code: "rate_limit_exceeded")
        ))
        await #expect(throws: GenerationError.rateLimited(retryAfter: 7)) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }

        StubURLProtocol.reset(.respond(status: 400, body: errorBody(code: "moderation_blocked")))
        await #expect(throws: GenerationError.contentRefused) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }

        StubURLProtocol.reset(.respond(status: 403, body: errorBody(message: "no images scope")))
        await #expect(throws: GenerationError.keyNotPermitted(apiMessage: "no images scope")) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }
    }

    @Test func nonJSONErrorBodyStillMapsByStatus() async {
        StubURLProtocol.reset(.respond(status: 502, body: Data("<html>bad gateway</html>".utf8)))
        await #expect(throws: GenerationError.serviceUnavailable) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, GenerationError.offline),
        (.networkConnectionLost, .offline),
        (.timedOut, .timeout),
        (.cannotConnectToHost, .serviceUnavailable),
    ])
    func transportErrorsAreRoutedThroughErrorMapper(code: URLError.Code, expected: GenerationError) async {
        StubURLProtocol.reset(.fail(code))
        await #expect(throws: expected) {
            try await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        }
    }

    // MARK: No retries (§5.3)

    @Test(arguments: [
        StubURLProtocol.Behavior.respond(status: 500),
        .respond(status: 429, headers: ["Retry-After": "1"]),
        .respond(status: 200, body: Data("{}".utf8)),
        .fail(.timedOut),
        .fail(.networkConnectionLost),
    ])
    func failureIsNeverRetried(behavior: StubURLProtocol.Behavior) async {
        StubURLProtocol.reset(behavior)
        _ = try? await makeClient().generate(prompt: "a happy cat", apiKey: apiKey)
        #expect(StubURLProtocol.recorded.count == 1)
    }

    // MARK: Cancellation (§5.3)

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        StubURLProtocol.reset(.hang)
        let client = makeClient()
        let key = apiKey
        let task = Task { try await client.generate(prompt: "a happy cat", apiKey: key) }

        // Wait until the request is actually in flight.
        try await waitUntil { StubURLProtocol.recorded.count == 1 }
        #expect(StubURLProtocol.stopLoadingCount == 0)

        task.cancel()

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        // The data task was cancelled, not abandoned: the protocol was stopped.
        try await waitUntil { StubURLProtocol.stopLoadingCount >= 1 }
        #expect(StubURLProtocol.recorded.count == 1)
    }

    @Test func aTaskCancelledBeforeStartingThrowsCancelled() async throws {
        StubURLProtocol.reset(.respond(status: 200, body: successBody()))
        let client = makeClient()
        let key = apiKey
        let task = Task {
            // Cancel ourselves before the request starts.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.generate(prompt: "a happy cat", apiKey: key)
        }
        await #expect(throws: GenerationError.cancelled) { try await task.value }

        // `generate` has already thrown, but URLSession still starts the
        // cancelled load on its own queue and the stub records it a moment
        // later. Drain it (the protocol is stopped right after it starts) so
        // it can't land in the next test's `reset`ed state.
        try await waitUntil { StubURLProtocol.stopLoadingCount >= 1 }
    }

    // MARK: Helpers

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
