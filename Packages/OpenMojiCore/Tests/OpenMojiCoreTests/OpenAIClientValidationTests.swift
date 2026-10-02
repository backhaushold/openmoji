import Foundation
import Testing
@testable import OpenMojiCore

/// `OpenAIClient.validate(key:)` against the `URLProtocol` stub (tech spec
/// §5.4, ADR-0009).
///
/// These are an extension of `OpenAIClientTests` on purpose: the stub's state
/// is process-wide and Swift Testing runs separate suites in parallel, so
/// only tests inside that one `.serialized` suite are safe from each other.
extension OpenAIClientTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private var candidateKey: String { "test-fake-key-0000" }

    private func makeValidationClient(model: String? = nil) -> OpenAIClient {
        let info: [String: Any] = model.map { ["OpenMojiImageModel": $0] } ?? [:]
        return OpenAIClient(
            config: GenerationConfig(infoDictionary: info),
            protocolClasses: [StubURLProtocol.self]
        )
    }

    /// The validation requests the stub saw.
    private func validationRequests() -> [URLRequest] {
        StubURLProtocol.recorded.map(\.request)
    }

    private func onlyValidationRequest() throws -> URLRequest {
        let requests = validationRequests()
        try #require(requests.count == 1)
        return requests[0]
    }

    // MARK: Request (§5.4)

    @Test func validationGetsTheConfiguredModelWithTheCandidateKey() async throws {
        StubURLProtocol.reset(.respond(status: 200))
        _ = await makeValidationClient(model: "gpt-image-test").validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-image-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(candidateKey)")
        #expect(request.httpBody == nil)
    }

    @Test func validationUsesTheDefaultModelWhenNoneIsConfigured() async throws {
        StubURLProtocol.reset(.respond(status: 200))
        _ = await makeValidationClient().validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-image-2.5-flare")
    }

    @Test func validationEscapesTheModelIDAsOnePathComponent() async throws {
        StubURLProtocol.reset(.respond(status: 200))
        _ = await makeValidationClient(model: "ft:my model/v2?x#y").validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(
            request.url?.absoluteString
                == "https://api.openai.com/v1/models/ft:my%20model%2Fv2%3Fx%23y"
        )
    }

    @Test func validationSendsOneRequestAndDoesNotRetry() async throws {
        StubURLProtocol.reset(.respond(status: 503))
        _ = await makeValidationClient().validate(key: candidateKey)

        #expect(validationRequests().count == 1)
    }

    // MARK: Results (§5.4)

    @Test func status200IsValid() async {
        StubURLProtocol.reset(.respond(status: 200, body: Data(#"{"id":"gpt-image-2.5-flare"}"#.utf8)))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .valid)
    }

    @Test func status401IsInvalid() async {
        StubURLProtocol.reset(.respond(status: 401))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .invalid)
    }

    @Test func status403IsNotPermitted() async {
        StubURLProtocol.reset(.respond(status: 403))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .notPermitted)
    }

    @Test func status404IsValidWithAModelNotVisibleWarning() async {
        StubURLProtocol.reset(.respond(status: 404))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .modelNotVisible)
    }

    @Test func offlineCanNotBeChecked() async {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            StubURLProtocol.reset(.fail(code))
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(result == .couldNotCheck)
        }
    }

    @Test func timeoutCanNotBeChecked() async {
        StubURLProtocol.reset(.fail(.timedOut))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .couldNotCheck)
    }

    // §5.4 is silent on these, so they read as "can't check": no verdict on
    // the key, and the user may still save.
    @Test func statusesWithNoVerdictCanNotBeChecked() async {
        for status in [400, 408, 429, 500, 502, 503] {
            StubURLProtocol.reset(.respond(status: status))
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(result == .couldNotCheck, "status \(status)")
        }
    }

    @Test func anyOtherTransportFailureCanNotBeChecked() async {
        StubURLProtocol.reset(.fail(.cannotConnectToHost))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .couldNotCheck)
    }

    // MARK: Save policy

    @Test func onlyTheVerdictsThatAcceptTheKeyAllowSaving() {
        #expect(KeyValidationResult.valid.allowsSaving)
        #expect(KeyValidationResult.modelNotVisible.allowsSaving)
        #expect(!KeyValidationResult.invalid.allowsSaving)
        #expect(!KeyValidationResult.notPermitted.allowsSaving)
        #expect(!KeyValidationResult.couldNotCheck.allowsSaving)
    }

    @Test func onlyCouldNotCheckOffersSaveAnyway() {
        #expect(KeyValidationResult.couldNotCheck.offersSaveAnyway)
        #expect(!KeyValidationResult.valid.offersSaveAnyway)
        #expect(!KeyValidationResult.modelNotVisible.offersSaveAnyway)
        #expect(!KeyValidationResult.invalid.offersSaveAnyway)
        #expect(!KeyValidationResult.notPermitted.offersSaveAnyway)
    }

    // MARK: Key hygiene (NFR-6)

    /// OpenAI's own 401 body echoes a redacted copy of the key. Whatever the
    /// response says, the result must not carry it.
    @Test func noResultDescriptionContainsTheKey() async {
        let echoing = Data(
            #"{"error":{"message":"Incorrect API key provided: \#(candidateKey)","type":"invalid_request_error","code":"invalid_api_key","param":null}}"#
                .utf8
        )
        let behaviors: [StubURLProtocol.Behavior] = [
            .respond(status: 200, body: echoing),
            .respond(status: 401, body: echoing),
            .respond(status: 403, body: echoing),
            .respond(status: 404, body: echoing),
            .respond(status: 500, body: echoing),
            .fail(.notConnectedToInternet),
            .fail(.timedOut),
        ]
        for behavior in behaviors {
            StubURLProtocol.reset(behavior)
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(!String(describing: result).contains(candidateKey))
            #expect(!String(reflecting: result).contains(candidateKey))
            #expect(!"\(result)".contains(candidateKey))
        }
    }
}
