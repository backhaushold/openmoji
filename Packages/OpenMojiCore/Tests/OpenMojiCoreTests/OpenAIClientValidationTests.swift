import Foundation
import Testing
@testable import OpenMojiCore

/// `OpenAIClient.validate(key:)` against the `URLProtocol` stub (tech spec
/// §5.4, ADR-0009).
///
/// These are an extension of `OpenAIClientTests` so they share its per-test
/// `stub`.
extension OpenAIClientTests {
    // A fake key on purpose: it must not look like `sk-...`.
    private var candidateKey: String { "test-fake-key-0000" }

    private func makeValidationClient(model: String? = nil) -> OpenAIClient {
        let info: [String: Any] = model.map { ["OpenMojiImageModel": $0] } ?? [:]
        return stub.makeClient(config: GenerationConfig(infoDictionary: info))
    }

    /// An OpenAI error body: `{"error": {"message", "type", "code", "param"}}`.
    private func errorBody(code: String?, message: String = "The model does not exist") -> Data {
        let code = code.map { #""\#($0)""# } ?? "null"
        return Data(
            #"{"error":{"message":"\#(message)","type":"invalid_request_error","code":\#(code),"param":null}}"#.utf8
        )
    }

    /// The validation requests the stub saw.
    private func validationRequests() -> [URLRequest] {
        stub.recorded.map(\.request)
    }

    private func onlyValidationRequest() throws -> URLRequest {
        let requests = validationRequests()
        try #require(requests.count == 1)
        return requests[0]
    }

    // MARK: Request (§5.4)

    @Test func validationGetsTheConfiguredModelWithTheCandidateKey() async throws {
        stub.reset(.respond(status: 200))
        _ = await makeValidationClient(model: "gpt-image-test").validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-image-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(candidateKey)")
        #expect(request.httpBody == nil)
    }

    @Test func validationUsesTheDefaultModelWhenNoneIsConfigured() async throws {
        stub.reset(.respond(status: 200))
        _ = await makeValidationClient().validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models/gpt-image-2.5-flare")
    }

    @Test func validationEscapesTheModelIDAsOnePathComponent() async throws {
        stub.reset(.respond(status: 200))
        _ = await makeValidationClient(model: "ft:my model/v2?x#y").validate(key: candidateKey)

        let request = try onlyValidationRequest()
        #expect(
            request.url?.absoluteString
                == "https://api.openai.com/v1/models/ft:my%20model%2Fv2%3Fx%23y"
        )
    }

    @Test func validationSendsOneRequestAndDoesNotRetry() async throws {
        stub.reset(.respond(status: 503))
        _ = await makeValidationClient().validate(key: candidateKey)

        #expect(validationRequests().count == 1)
    }

    // MARK: Results (§5.4)

    @Test func status200IsValid() async {
        stub.reset(.respond(status: 200, body: Data(#"{"id":"gpt-image-2.5-flare"}"#.utf8)))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .valid)
    }

    @Test func status401IsInvalid() async {
        stub.reset(.respond(status: 401))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .invalid)
    }

    @Test func status403IsNotPermitted() async {
        stub.reset(.respond(status: 403))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .notPermitted)
    }

    @Test func status404IsValidWithAModelNotVisibleWarning() async {
        stub.reset(.respond(status: 404))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .modelNotVisible)
    }

    /// OpenAI doesn't document the no-access status. Project-scoped keys
    /// without model access are reported to get 403 with this code, so it
    /// reads like 404 (OQ-6).
    @Test func status403WithModelNotFoundIsValidWithAModelNotVisibleWarning() async {
        stub.reset(.respond(status: 403, body: errorBody(code: "model_not_found")))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .modelNotVisible)
    }

    @Test func status403WithAnyOtherCodeIsStillNotPermitted() async {
        let bodies = [
            errorBody(code: "insufficient_permissions"),
            errorBody(code: nil),
            // The code field decides, not the words in the message.
            errorBody(code: "unsupported_country_region_territory", message: "model_not_found"),
            Data(#"{"code":"model_not_found"}"#.utf8),
            Data("<html>Forbidden</html>".utf8),
        ]
        for (index, body) in bodies.enumerated() {
            stub.reset(.respond(status: 403, body: body))
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(result == .notPermitted, "body #\(index)")
        }
    }

    /// Only 403 and 404 mean "model not visible": the code on another status
    /// changes nothing.
    @Test func modelNotFoundCodeOnOtherStatusesChangesNothing() async {
        let expected: [(status: Int, result: KeyValidationResult)] = [
            (401, .invalid), (429, .couldNotCheck), (500, .couldNotCheck),
        ]
        for (status, result) in expected {
            stub.reset(.respond(status: status, body: errorBody(code: "model_not_found")))
            #expect(await makeValidationClient().validate(key: candidateKey) == result, "status \(status)")
        }
    }

    @Test func offlineCanNotBeChecked() async {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed] {
            stub.reset(.fail(code))
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(result == .couldNotCheck)
        }
    }

    @Test func timeoutCanNotBeChecked() async {
        stub.reset(.fail(.timedOut))
        let result = await makeValidationClient().validate(key: candidateKey)
        #expect(result == .couldNotCheck)
    }

    // §5.4 is silent on these, so they read as "can't check": no verdict on
    // the key, and the user may still save.
    @Test func statusesWithNoVerdictCanNotBeChecked() async {
        for status in [400, 408, 429, 500, 502, 503] {
            stub.reset(.respond(status: status))
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(result == .couldNotCheck, "status \(status)")
        }
    }

    @Test func anyOtherTransportFailureCanNotBeChecked() async {
        stub.reset(.fail(.cannotConnectToHost))
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
            .respond(status: 403, body: errorBody(code: "model_not_found", message: "No access for \(candidateKey)")),
            .respond(status: 404, body: echoing),
            .respond(status: 500, body: echoing),
            .fail(.notConnectedToInternet),
            .fail(.timedOut),
        ]
        for behavior in behaviors {
            stub.reset(behavior)
            let result = await makeValidationClient().validate(key: candidateKey)
            #expect(!String(describing: result).contains(candidateKey))
            #expect(!String(reflecting: result).contains(candidateKey))
            #expect(!"\(result)".contains(candidateKey))
        }
    }
}
