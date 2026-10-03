import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import OpenMojiCore

/// `GenerationService` against a `URLProtocol` stub (tech spec §2 flow, §5, §6,
/// §7.2): template, request, decode, process, and the `GenerationError` each
/// failure path ends in. Each test gets a fresh instance of this struct, so
/// `stub` is that test's own stub state.
@Suite(.serialized) struct GenerationServiceTests {
    // Built at runtime, in the same shape as a real project key, so no
    // OpenAI-key-shaped literal sits in the tree for gitleaks (ADR-0012). The
    // leak checks below look for this exact value.
    private let apiKey = ["sk", "proj", "ServiceSentinel", String(repeating: "k4Z", count: 12)]
        .joined(separator: "-")

    private let stub = StubURLProtocol.Stub()

    private var credentials: InMemoryCredentialStore { InMemoryCredentialStore(key: apiKey) }

    private func makeService(
        credentials: (any CredentialStore)? = nil,
        config: GenerationConfig = GenerationConfig(infoDictionary: [:])
    ) -> GenerationService {
        GenerationService(
            credentials: credentials ?? self.credentials,
            client: stub.makeClient(config: config),
            config: config
        )
    }

    // MARK: Fixtures

    /// A real 1024 x 1024 PNG: a transparent square with an opaque circle.
    private static func circlePNG() throws -> Data {
        struct FixtureError: Error {}
        guard
            let context = CGContext(
                data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FixtureError() }
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.7, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 100, y: 100, width: 824, height: 824))
        let data = NSMutableData()
        guard
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureError() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError() }
        return data as Data
    }

    private func successBody(base64: String) -> Data {
        Data(#"{"created": 1, "data": [{"b64_json": "\#(base64)"}]}"#.utf8)
    }

    private func successBody(image: Data) -> Data {
        successBody(base64: image.base64EncodedString())
    }

    private func errorBody(message: String = "msg", type: String? = nil, code: String? = nil) -> Data {
        func json(_ s: String?) -> Any { s ?? NSNull() }
        let object: [String: Any] = [
            "error": ["message": message, "type": json(type), "code": json(code), "param": NSNull()],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Success

    @Test func successReturnsAProcessedStickerWithEveryField() async throws {
        let image = try Self.circlePNG()
        stub.reset(.respond(status: 200, body: successBody(image: image)))
        let config = GenerationConfig(infoDictionary: [
            "OpenMojiImageModel": "gpt-image-test-model",
            "OpenMojiImageQuality": "high",
        ])

        let sticker = try await makeService(config: config).generate(prompt: "a happy cat")

        #expect(sticker.prompt == "a happy cat")
        #expect(sticker.modelID == "gpt-image-test-model")
        #expect(sticker.quality == "high")
        #expect(sticker.edge == 618)  // a clean 1024 x 1024 circle fits at the top of the ladder
        #expect(sticker.png.count < 500_000)
        #expect(sticker.png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(sticker.png == (try makeSticker(from: image)).png)
    }

    @Test func modelAndQualityDefaultToTheConfigDefaults() async throws {
        stub.reset(.respond(status: 200, body: successBody(image: try Self.circlePNG())))

        let sticker = try await makeService().generate(prompt: "a happy cat")

        #expect(sticker.modelID == "gpt-image-2.5-flare")
        #expect(sticker.quality == "medium")
    }

    @Test func requestPromptIsTheRenderedTemplateAndTheStickerKeepsTheUsersPrompt() async throws {
        stub.reset(.respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let userPrompt = "  a \"quoted\" cat \u{1F431}\n"

        let sticker = try await makeService().generate(prompt: userPrompt)

        let recorded = try #require(stub.recorded.first)
        let body = try #require(recorded.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == StyleTemplate.render(userPrompt))
        #expect(json["prompt"] as? String != userPrompt)
        // The user's text, not the rendered template, is what Keep stores.
        #expect(sticker.prompt == userPrompt)
    }

    @Test func sendsTheStoredKeyAsTheBearerToken() async throws {
        stub.reset(.respond(status: 200, body: successBody(image: try Self.circlePNG())))

        _ = try await makeService().generate(prompt: "a happy cat")

        let recorded = try #require(stub.recorded.first)
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(stub.recorded.count == 1)
    }

    // MARK: Failure paths (§6)

    @Test(arguments: [
        (401, [:], "invalid_api_key", "invalid_request_error", GenerationError.invalidKey),
        (429, [:], "insufficient_quota", "insufficient_quota", .budgetExhausted),
        (429, ["Retry-After": "7"], "rate_limit_exceeded", "requests", .rateLimited(retryAfter: 7)),
        (400, [:], "moderation_blocked", "image_generation_user_error", .contentRefused),
        (500, [:], "server_error", "server_error", .serviceUnavailable),
        (503, [:], "server_is_overloaded", "server_error", .serviceUnavailable),
    ] as [(Int, [String: String], String, String, GenerationError)])
    func httpFailureMapsToItsGenerationError(
        status: Int, headers: [String: String], code: String, type: String, expected: GenerationError
    ) async {
        stub.reset(.respond(status: status, headers: headers, body: errorBody(type: type, code: code)))

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }
        #expect(stub.recorded.count == 1)  // no retries (§5.3)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, GenerationError.offline),
        (.networkConnectionLost, .offline),
        (.timedOut, .timeout),
    ])
    func transportFailureMapsToItsGenerationError(code: URLError.Code, expected: GenerationError) async {
        stub.reset(.fail(code))

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }
    }

    @Test func badBase64IsProcessingFailed() async {
        stub.reset(.respond(status: 200, body: successBody(base64: "not base64!!")))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func aResponseWithoutAnImageIsProcessingFailed() async {
        stub.reset(.respond(status: 200, body: Data(#"{"data": []}"#.utf8)))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func validBase64OfACorruptPNGIsProcessingFailed() async {
        let garbage = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        stub.reset(.respond(status: 200, body: successBody(image: garbage)))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func aTruncatedPNGIsProcessingFailed() async throws {
        let image = try Self.circlePNG()
        stub.reset(.respond(status: 200, body: successBody(image: image.prefix(40))))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    // MARK: No key (FR-5)

    @Test func noKeyIsInvalidKeyAndNothingIsSent() async {
        stub.reset(.respond(status: 200, body: Data()))

        await #expect(throws: GenerationError.invalidKey) {
            try await makeService(credentials: InMemoryCredentialStore(key: nil))
                .generate(prompt: "a happy cat")
        }
        #expect(stub.recorded.isEmpty)
    }

    @Test func anUnreadableKeychainIsInvalidKeyAndNothingIsSent() async {
        stub.reset(.respond(status: 200, body: Data()))

        await #expect(throws: GenerationError.invalidKey) {
            try await makeService(credentials: UnreadableCredentialStore())
                .generate(prompt: "a happy cat")
        }
        #expect(stub.recorded.isEmpty)
    }

    @Test func noFailureMentionsTheKey() async {
        let failures: [StubURLProtocol.Behavior] = [
            .respond(status: 401, body: errorBody(message: "Incorrect API key provided: \(apiKey)", code: "invalid_api_key")),
            .respond(status: 200, body: successBody(base64: "not base64!!")),
            .fail(.timedOut),
        ]
        for behavior in failures {
            stub.reset(behavior)
            do {
                _ = try await makeService().generate(prompt: "a happy cat")
                Issue.record("expected a failure")
            } catch {
                for text in ["\(error)", String(reflecting: error), error.userMessage ?? ""] {
                    #expect(!text.contains(apiKey) && !text.contains("sk-"), "\(text)")
                }
            }
        }
    }

    // MARK: Cancellation (FR-10)

    @Test func cancellingTheTaskThrowsCancelledAndCancelsTheRequest() async throws {
        stub.reset(.hang)
        let service = makeService()
        let task = Task { try await service.generate(prompt: "a happy cat") }

        try await waitUntil { stub.recorded.count == 1 }
        task.cancel()

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        try await waitUntil { stub.stopLoadingCount >= 1 }
    }

    @Test func aTaskCancelledBeforeStartingThrowsCancelledAndSendsNothing() async {
        stub.reset(.respond(status: 200, body: successBody(base64: "AAAA")))
        let service = makeService()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.generate(prompt: "a happy cat")
        }

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        #expect(stub.recorded.isEmpty)
    }

    @Test func aCancelThatLandsDuringProcessingDropsTheResult() async throws {
        stub.reset(.respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let processed = Mutex(false)
        // Cancels the calling task from inside the processing step, so the
        // cancel lands after the response and the result must be dropped.
        let service = GenerationService(
            credentials: credentials,
            client: stub.makeClient(),
            config: GenerationConfig(infoDictionary: [:])
        ) { data in
            processed.withLock { $0 = true }
            withUnsafeCurrentTask { $0?.cancel() }
            return try makeSticker(from: data)
        }
        let task = Task { try await service.generate(prompt: "a happy cat") }

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        #expect(processed.withLock { $0 })
    }

    // MARK: Off the main actor (§7.2)

    @MainActor @Test func processingRunsOffTheMainActor() async throws {
        // The test itself is on the main thread, so a service that ran its
        // steps inline in the caller would see `true` below.
        #expect(Self.isMainThread)
        stub.reset(.respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let ranOnMain = Mutex<Bool?>(nil)
        let service = GenerationService(
            credentials: credentials,
            client: stub.makeClient(),
            config: GenerationConfig(infoDictionary: [:])
        ) { data in
            ranOnMain.withLock { $0 = Self.isMainThread }
            return try makeSticker(from: data)
        }

        _ = try await service.generate(prompt: "a happy cat")

        #expect(ranOnMain.withLock { $0 } == false)
    }

    /// Sync so it can be called from the processing closure and the test alike.
    private static var isMainThread: Bool { pthread_main_np() != 0 }

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

/// A Keychain that can't be read, for example a missing entitlement.
private struct UnreadableCredentialStore: CredentialStore {
    func load() throws -> String? { throw CredentialStoreError.keychain(-34018) }
    func save(_ key: String) throws {}
    func clear() throws {}
}
