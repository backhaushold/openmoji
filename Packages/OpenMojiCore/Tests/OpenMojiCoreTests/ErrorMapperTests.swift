import Foundation
import Testing
@testable import OpenMojiCore

/// One canned case per row of tech spec §6 (FR-22), in table order, plus
/// the ordering rules, Retry-After parsing and secret hygiene.
@Suite struct ErrorMapperTests {
    // MARK: Helpers

    /// An OpenAI error body: {"error": {"message", "type", "code", "param"}}.
    private func body(
        message: String = "msg",
        type: String? = nil,
        code: String? = nil,
        param: String? = nil
    ) -> Data {
        func json(_ s: String?) -> Any { s ?? NSNull() }
        let object: [String: Any] = [
            "error": [
                "message": message,
                "type": json(type),
                "code": json(code),
                "param": json(param),
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func map(
        _ status: Int,
        headers: [String: String] = [:],
        type: String? = nil,
        code: String? = nil,
        message: String = "msg"
    ) -> GenerationError {
        ErrorMapper.map(
            status: status,
            headers: headers,
            body: body(message: message, type: type, code: code)
        )
    }

    /// Every way an error can be rendered to text.
    private func renderings(of error: GenerationError) -> [String] {
        [
            "\(error)",
            String(reflecting: error),
            error.localizedDescription,
            error.userMessage ?? "",
        ]
    }

    // MARK: Row 1: cancelled

    @Test func cancellationErrorIsCancelled() {
        #expect(ErrorMapper.map(CancellationError()) == .cancelled)
    }

    @Test func urlErrorCancelledIsCancelled() {
        #expect(ErrorMapper.map(URLError(.cancelled)) == .cancelled)
    }

    @Test func cancelledHasNoUserMessage() {
        #expect(GenerationError.cancelled.userMessage == nil)
    }

    // MARK: Row 2: offline

    @Test(arguments: [
        URLError.Code.notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .internationalRoamingOff,
    ])
    func connectivityURLErrorsAreOffline(code: URLError.Code) {
        let error = ErrorMapper.map(URLError(code))
        #expect(error == .offline)
        #expect(error.userMessage
            == "You're offline. Your stickers still work; making new ones needs internet.")
    }

    // MARK: Row 3: timeout

    @Test func urlErrorTimedOutIsTimeout() {
        let error = ErrorMapper.map(URLError(.timedOut))
        #expect(error == .timeout)
        #expect(error.userMessage == "That took too long. Try again.")
    }

    // MARK: Row 4: 401

    @Test func http401IsInvalidKey() {
        let error = map(401, type: "invalid_request_error", code: "invalid_api_key")
        #expect(error == .invalidKey)
        #expect(error.userMessage == "The OpenAI key isn't working. Check it in Settings.")
    }

    // MARK: Row 5: 403

    @Test func http403IsKeyNotPermittedAndCarriesApiMessage() {
        let error = map(403, message: "Project does not have access to this model.")
        #expect(error == .keyNotPermitted(apiMessage: "Project does not have access to this model."))
        #expect(error.userMessage
            == "This key isn't allowed to make images. Project does not have access to this model.")
    }

    @Test func http403WithoutApiMessageUsesBaseMessageOnly() {
        let error = ErrorMapper.map(status: 403, headers: [:], body: Data())
        #expect(error == .keyNotPermitted(apiMessage: nil))
        #expect(error.userMessage == "This key isn't allowed to make images.")
    }

    // MARK: Row 6: 429 billing family

    @Test(arguments: [
        "credit_balance_exhausted",
        "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded",
        "organization_usage_limit_exceeded",
        "insufficient_quota",
    ])
    func billing429CodesAreBudgetExhausted(code: String) {
        let error = map(429, type: "billing_error", code: code)
        #expect(error == .budgetExhausted)
        #expect(error.userMessage
            == "The sticker budget is used up. Ask the family admin to top it up.")
    }

    @Test func insufficientQuotaTypeIsBudgetExhaustedEvenWithOtherCode() {
        #expect(map(429, type: "insufficient_quota", code: "something_else") == .budgetExhausted)
        #expect(map(429, type: "insufficient_quota", code: nil) == .budgetExhausted)
    }

    @Test func billingCodeBeatsRetryAfter() {
        let error = map(429, headers: ["Retry-After": "20"], type: "insufficient_quota", code: "insufficient_quota")
        #expect(error == .budgetExhausted)
    }

    // MARK: Row 7: 429 rate-limit family

    @Test(arguments: ["rate_limit_exceeded", "slow_down", "anything_else"])
    func other429CodesAreRateLimited(code: String) {
        let error = map(429, headers: ["Retry-After": "7"], type: "requests", code: code)
        #expect(error == .rateLimited(retryAfter: 7))
        #expect(error.userMessage == "Too many stickers at once. Try again in 7 seconds.")
    }

    @Test func rateLimitedWithNoBodyAtAll() {
        #expect(ErrorMapper.map(status: 429, headers: [:], body: Data())
            == .rateLimited(retryAfter: nil))
    }

    @Test func rateLimitedWithoutRetryAfterHasNoNumber() {
        let error = map(429, code: "rate_limit_exceeded")
        #expect(error == .rateLimited(retryAfter: nil))
        #expect(error.userMessage == "Too many stickers at once. Try again in a moment.")
    }

    @Test func rateLimitedMessageSingularisesOneSecond() {
        #expect(GenerationError.rateLimited(retryAfter: 1).userMessage
            == "Too many stickers at once. Try again in 1 second.")
    }

    // MARK: Retry-After parsing

    @Test func retryAfterHeaderNameIsCaseInsensitive() {
        #expect(map(429, headers: ["retry-after": "12"]) == .rateLimited(retryAfter: 12))
        #expect(map(429, headers: ["RETRY-AFTER": "12"]) == .rateLimited(retryAfter: 12))
    }

    @Test func retryAfterToleratesSurroundingWhitespace() {
        #expect(map(429, headers: ["Retry-After": " 30 "]) == .rateLimited(retryAfter: 30))
    }

    @Test func retryAfterHttpDateIsConvertedToSecondsFromNow() {
        let now = Date(timeIntervalSince1970: 1_790_975_700)
        // 90 seconds after `now`, in IMF-fixdate form.
        let header = "Fri, 02 Oct 2026 21:16:30 GMT"
        let error = ErrorMapper.map(
            status: 429, headers: ["Retry-After": header], body: Data(), now: now
        )
        #expect(error == .rateLimited(retryAfter: 90))
    }

    @Test(arguments: ["", "soon", "-5", "0", "1.5", "Thu, 01 Jan 1970 00:00:00 GMT"])
    func unusableRetryAfterIsIgnored(value: String) {
        #expect(map(429, headers: ["Retry-After": value]) == .rateLimited(retryAfter: nil))
    }

    // MARK: Row 8: content refused

    @Test func moderationBlockedCodeIsContentRefused() {
        let error = map(400, type: "image_generation_user_error", code: "moderation_blocked")
        #expect(error == .contentRefused)
        #expect(error.userMessage == "OpenAI won't make that one. Try wording it differently.")
    }

    @Test func moderationBlockedCodeAloneIsContentRefused() {
        #expect(map(400, type: "invalid_request_error", code: "moderation_blocked") == .contentRefused)
    }

    @Test func imageGenerationUserErrorTypeAloneIsContentRefused() {
        #expect(map(400, type: "image_generation_user_error", code: nil) == .contentRefused)
    }

    @Test func contentRefusedMatchesRegardlessOfStatus() {
        // The refusal status is undocumented, so type/code decide, not 400.
        #expect(map(422, code: "moderation_blocked") == .contentRefused)
        #expect(map(500, type: "image_generation_user_error") == .contentRefused)
    }

    // MARK: Row 9: model unavailable

    @Test func http404IsModelUnavailableAndCarriesApiMessage() {
        let error = map(404, message: "The model `gpt-image-2.5-flare` does not exist.")
        #expect(error == .modelUnavailable(apiMessage: "The model `gpt-image-2.5-flare` does not exist."))
        #expect(error.userMessage
            == "The image model isn't available on this account. The model `gpt-image-2.5-flare` does not exist.")
    }

    @Test func modelNotFoundCodeIsModelUnavailableRegardlessOfStatus() {
        #expect(map(400, code: "model_not_found", message: "nope") == .modelUnavailable(apiMessage: "nope"))
    }

    // MARK: Row 10: service unavailable

    @Test(arguments: [500, 502, 503, 504, 599])
    func http5xxIsServiceUnavailable(status: Int) {
        let error = map(status)
        #expect(error == .serviceUnavailable)
        #expect(error.userMessage == "OpenAI is having trouble. Try again shortly.")
    }

    @Test func http503ServerIsOverloadedIsServiceUnavailable() {
        #expect(map(503, type: "server_error", code: "server_is_overloaded") == .serviceUnavailable)
    }

    @Test func http5xxWithHtmlBodyIsServiceUnavailable() {
        let html = Data("<html>Bad gateway</html>".utf8)
        #expect(ErrorMapper.map(status: 502, headers: [:], body: html) == .serviceUnavailable)
    }

    // MARK: Row 11: other 4xx

    @Test func otherClientErrorsAreApiWithStatusAndMessage() {
        let error = map(400, type: "invalid_request_error", code: "invalid_value", message: "Bad size.")
        #expect(error == .api(status: 400, apiMessage: "Bad size."))
        #expect(error.userMessage == "Something went wrong: Bad size.")
    }

    @Test func apiWithoutMessageDropsTheSuffix() {
        let error = ErrorMapper.map(status: 418, headers: [:], body: Data())
        #expect(error == .api(status: 418, apiMessage: nil))
        #expect(error.userMessage == "Something went wrong.")
    }

    @Test func nullAndNumericFieldsAreTolerated() {
        let raw = Data(#"{"error":{"message":null,"type":null,"code":1234,"param":null}}"#.utf8)
        #expect(ErrorMapper.map(status: 400, headers: [:], body: raw)
            == .api(status: 400, apiMessage: nil))
    }

    // MARK: Row 12: processing failed

    @Test func processingFailedHasItsMessage() {
        #expect(GenerationError.processingFailed.userMessage
            == "Couldn't turn that into a sticker. Try again.")
    }

    // MARK: Ordering

    @Test func unauthorisedBeatsContentRefusedAndModelRows() {
        #expect(map(401, code: "moderation_blocked") == .invalidKey)
        #expect(map(403, code: "model_not_found", message: "m") == .keyNotPermitted(apiMessage: "m"))
    }

    @Test func rateLimitedBeatsModelRowForSameStatus() {
        #expect(map(429, code: "model_not_found") == .rateLimited(retryAfter: nil))
    }

    // MARK: Fallbacks outside the §6 table

    @Test func unlistedTransportErrorsAreServiceUnavailable() {
        struct Unknown: Error {}
        #expect(ErrorMapper.map(URLError(.cannotFindHost)) == .serviceUnavailable)
        #expect(ErrorMapper.map(URLError(.secureConnectionFailed)) == .serviceUnavailable)
        #expect(ErrorMapper.map(Unknown()) == .serviceUnavailable)
    }

    @Test func generationErrorPassesThroughUnchanged() {
        #expect(ErrorMapper.map(GenerationError.processingFailed) == .processingFailed)
        #expect(ErrorMapper.map(GenerationError.rateLimited(retryAfter: 3)) == .rateLimited(retryAfter: 3))
    }

    @Test func nonErrorStatusFallsBackToApi() {
        #expect(ErrorMapper.map(status: 302, headers: [:], body: Data())
            == .api(status: 302, apiMessage: nil))
    }

    // MARK: Secret hygiene (NFR-6)

    private var everyCase: [GenerationError] {
        [
            .cancelled, .offline, .timeout, .invalidKey,
            .keyNotPermitted(apiMessage: "m"), .budgetExhausted,
            .rateLimited(retryAfter: 5), .contentRefused,
            .modelUnavailable(apiMessage: "m"), .serviceUnavailable,
            .api(status: 400, apiMessage: "m"), .processingFailed,
        ]
    }

    @Test func noErrorDescriptionContainsAKeyPrefix() {
        for error in everyCase {
            for text in renderings(of: error) {
                #expect(!text.contains("sk-"), "\(text)")
            }
        }
    }

    @Test func keyEchoedInApiMessageIsRedacted() {
        // OpenAI messages can echo a (masked) key; it must not reach a case.
        let echoed = "Incorrect API key provided: sk-proj-abc123****wxyz. See the docs."
        for error in [map(403, message: echoed), map(404, message: echoed), map(400, message: echoed)] {
            for text in renderings(of: error) {
                #expect(!text.contains("sk-"), "\(text)")
                #expect(!text.contains("abc123"), "\(text)")
            }
        }
        #expect(map(403, message: echoed).userMessage
            == "This key isn't allowed to make images. Incorrect API key provided: [redacted]. See the docs.")
    }

    @Test func everyCaseExceptCancelledHasAMessage() {
        for error in everyCase where error != .cancelled {
            #expect(error.userMessage?.isEmpty == false)
        }
    }
}
