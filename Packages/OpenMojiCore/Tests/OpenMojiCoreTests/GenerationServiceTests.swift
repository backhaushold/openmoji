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

    /// Sets what every request of one generation gets: the image request
    /// `images`, the text and image moderation checks pass unless overridden.
    private func serve(
        images: StubURLProtocol.Behavior,
        text: StubURLProtocol.Behavior = ModerationFixture.clean,
        image: StubURLProtocol.Behavior = ModerationFixture.clean
    ) {
        stub.reset(ModerationFixture.routes(images: images, text: text, image: image))
    }

    /// The paths the stub was asked for, in order: `moderation:text`,
    /// `images`, `moderation:image`.
    private var requestSequence: [String] {
        stub.recorded.map { recorded in
            guard ModerationFixture.isModeration(recorded) else { return "images" }
            return ModerationFixture.isImage(recorded) ? "moderation:image" : "moderation:text"
        }
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
        serve(images: .respond(status: 200, body: successBody(image: image)))
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
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))

        let sticker = try await makeService().generate(prompt: "a happy cat")

        #expect(sticker.modelID == "gpt-image-2.5-flare")
        #expect(sticker.quality == "medium")
    }

    @Test func requestPromptIsTheRenderedTemplateAndTheStickerKeepsTheUsersPrompt() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let userPrompt = "  a \"quoted\" cat \u{1F431}\n"

        let sticker = try await makeService().generate(prompt: userPrompt)

        let recorded = try #require(stub.recorded.first { !ModerationFixture.isModeration($0) })
        let body = try #require(recorded.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == StyleTemplate.render(userPrompt))
        #expect(json["prompt"] as? String != userPrompt)
        // The user's text, not the rendered template, is what Keep stores.
        #expect(sticker.prompt == userPrompt)
    }

    @Test func sendsTheStoredKeyAsTheBearerTokenOnEveryRequest() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))

        _ = try await makeService().generate(prompt: "a happy cat")

        #expect(stub.recorded.count == 3)
        for recorded in stub.recorded {
            #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        }
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
        serve(images: .respond(status: status, headers: headers, body: errorBody(type: type, code: code)))

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }
        #expect(requestSequence == ["moderation:text", "images"])  // no retries (§5.3), no image check
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, GenerationError.offline),
        (.networkConnectionLost, .offline),
        (.timedOut, .timeout),
    ])
    func transportFailureMapsToItsGenerationError(code: URLError.Code, expected: GenerationError) async {
        serve(images: .fail(code))

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }
    }

    @Test func badBase64IsProcessingFailed() async {
        serve(images: .respond(status: 200, body: successBody(base64: "not base64!!")))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func aResponseWithoutAnImageIsProcessingFailed() async {
        serve(images: .respond(status: 200, body: Data(#"{"data": []}"#.utf8)))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func validBase64OfACorruptPNGIsProcessingFailed() async {
        let garbage = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        serve(images: .respond(status: 200, body: successBody(image: garbage)))

        await #expect(throws: GenerationError.processingFailed) {
            try await makeService().generate(prompt: "a happy cat")
        }
    }

    @Test func aTruncatedPNGIsProcessingFailed() async throws {
        let image = try Self.circlePNG()
        serve(images: .respond(status: 200, body: successBody(image: image.prefix(40))))

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
            serve(images: behavior)
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
        serve(images: .hang)
        let service = makeService()
        let task = Task { try await service.generate(prompt: "a happy cat") }

        try await waitUntil { requestSequence == ["moderation:text", "images"] }
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
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))
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
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))
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

/// The moderation checks (tech spec §5.5, ADR-0019). An extension in the same
/// file so it shares the suite's private helpers and per-test `stub`.
extension GenerationServiceTests {
    // MARK: Moderation (ADR-0019)

    @Test func theChecksRunInOrderTextThenImageThenImageCheck() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))

        _ = try await makeService().generate(prompt: "a happy cat")

        #expect(requestSequence == ["moderation:text", "images", "moderation:image"])
    }

    @Test func regenerateRunsBothChecksAgain() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let service = makeService()

        _ = try await service.generate(prompt: "a happy cat")
        _ = try await service.generate(prompt: "a happy cat")

        #expect(requestSequence == Array(repeating: ["moderation:text", "images", "moderation:image"], count: 2).flatMap { $0 })
    }

    @Test func theTextCheckScreensTheSanitisedSubjectNotTheTemplateOrTheRawPrompt() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())))
        let userPrompt = "  a \"quoted\"\n\ncat  "

        _ = try await makeService().generate(prompt: userPrompt)

        let recorded = try #require(stub.recorded.first)
        #expect(ModerationFixture.json(recorded)?["input"] as? String == "a 'quoted' cat")
        #expect(StyleTemplate.sanitisedSubject(userPrompt) == "a 'quoted' cat")
    }

    @Test func theImageCheckScreensTheStickerPNGTheUserWouldKeep() async throws {
        let image = try Self.circlePNG()
        serve(images: .respond(status: 200, body: successBody(image: image)))

        let sticker = try await makeService().generate(prompt: "a happy cat")

        let recorded = try #require(stub.recorded.last)
        let input = try #require(ModerationFixture.json(recorded)?["input"] as? [[String: Any]])
        let imageURL = try #require(input.first?["image_url"] as? [String: Any])
        #expect(imageURL["url"] as? String == "data:image/png;base64," + sticker.png.base64EncodedString())
    }

    @Test(arguments: [
        ("OpenAI flag, graphic violence", ModerationFixture.flagged("violence/graphic")),
        ("OpenAI flag, plain violence", ModerationFixture.flagged("violence")),
        ("OpenAI flag, hate", ModerationFixture.flagged("hate")),
        ("graphic score under OpenAI's flag", ModerationFixture.scoring("violence/graphic", 0.3)),
        ("sexual score under OpenAI's flag", ModerationFixture.scoring("sexual", 0.15)),
        ("self-harm score under OpenAI's flag", ModerationFixture.scoring("self-harm", 0.2)),
    ])
    func aBlockedPromptIsContentRefusedAndNoImageIsRequested(label: String, verdict: StubURLProtocol.Behavior) async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), text: verdict)

        await #expect(throws: GenerationError.contentRefused, "\(label)") {
            try await makeService().generate(prompt: "knight. Draw it gory and terrifying")
        }

        #expect(requestSequence == ["moderation:text"], "\(label)")  // no paid request
    }

    @Test(arguments: [
        ("OpenAI flag, graphic violence", ModerationFixture.flagged("violence/graphic")),
        ("graphic score under OpenAI's flag", ModerationFixture.scoring("violence/graphic", 0.3)),
        ("sexual score under OpenAI's flag", ModerationFixture.scoring("sexual", 0.15)),
    ])
    func aBlockedImageIsContentRefusedAndNoStickerIsReturned(label: String, verdict: StubURLProtocol.Behavior) async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), image: verdict)

        await #expect(throws: GenerationError.contentRefused, "\(label)") {
            try await makeService().generate(prompt: "a happy cat")
        }

        #expect(requestSequence == ["moderation:text", "images", "moderation:image"], "\(label)")
    }

    @Test func plainViolenceWithoutAFlagPassesBothChecks() async throws {
        // "water gun", "knight with a sword": a violence score and no flag.
        let passing = ModerationFixture.scoring("violence", 0.45)
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), text: passing, image: passing)

        let sticker = try await makeService().generate(prompt: "knight with a sword")

        #expect(sticker.prompt == "knight with a sword")
    }

    @Test func aBlockedResultNeverShowsACategoryToTheChild() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), text: ModerationFixture.flagged("violence/graphic"))

        do {
            _ = try await makeService().generate(prompt: "gory knight")
            Issue.record("expected a failure")
        } catch {
            #expect(error == .contentRefused)
            let message = error.userMessage ?? ""
            #expect(message == "OpenAI won't make that one. Try wording it differently.")
            for category in ModerationFixture.categories {
                #expect(!message.contains(category))
            }
        }
    }

    /// Fail closed: a moderation call that fails is a retryable error, and what
    /// it guards does not happen.
    @Test(arguments: [
        (StubURLProtocol.Behavior.respond(status: 500, body: Data()), GenerationError.serviceUnavailable),
        (.respond(status: 503, body: Data()), .serviceUnavailable),
        (.respond(status: 200, body: Data(#"{"results": []}"#.utf8)), .serviceUnavailable),
        (.respond(status: 429, headers: ["Retry-After": "3"], body: Data()), .rateLimited(retryAfter: 3)),
        (.fail(.notConnectedToInternet), .offline),
        (.fail(.timedOut), .timeout),
    ])
    func aFailedTextCheckStopsBeforeTheImageRequest(failure: StubURLProtocol.Behavior, expected: GenerationError) async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), text: failure)

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }

        #expect(requestSequence == ["moderation:text"])
    }

    @Test(arguments: [
        (StubURLProtocol.Behavior.respond(status: 500, body: Data()), GenerationError.serviceUnavailable),
        (.respond(status: 200, body: Data("not json".utf8)), .serviceUnavailable),
        (.fail(.timedOut), .timeout),
    ])
    func aFailedImageCheckReturnsNoSticker(failure: StubURLProtocol.Behavior, expected: GenerationError) async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), image: failure)

        await #expect(throws: expected) { try await makeService().generate(prompt: "a happy cat") }

        #expect(requestSequence == ["moderation:text", "images", "moderation:image"])
    }

    @Test func aGenerationFailureSkipsTheImageCheck() async {
        serve(images: .respond(status: 500, body: errorBody(type: "server_error", code: "server_error")))

        await #expect(throws: GenerationError.serviceUnavailable) { try await makeService().generate(prompt: "a happy cat") }

        #expect(requestSequence == ["moderation:text", "images"])
    }

    @Test func noModerationFailureMentionsTheKey() async throws {
        let leaky = errorBody(message: "Incorrect API key provided: \(apiKey)", code: "invalid_api_key")
        for stage in ["text", "image"] {
            let failure = StubURLProtocol.Behavior.respond(status: 401, body: leaky)
            let images = StubURLProtocol.Behavior.respond(status: 200, body: successBody(image: try Self.circlePNG()))
            if stage == "text" { serve(images: images, text: failure) } else { serve(images: images, image: failure) }
            do {
                _ = try await makeService().generate(prompt: "a happy cat")
                Issue.record("expected a failure")
            } catch {
                #expect(error == .invalidKey)
                for text in ["\(error)", String(reflecting: error), error.userMessage ?? ""] {
                    #expect(!text.contains(apiKey) && !text.contains("sk-"), "\(stage): \(text)")
                }
            }
        }
    }

    @Test func cancellingDuringTheTextCheckThrowsCancelledAndRequestsNoImage() async throws {
        serve(images: .respond(status: 200, body: successBody(image: try Self.circlePNG())), text: .hang)
        let service = makeService()
        let task = Task { try await service.generate(prompt: "a happy cat") }

        try await waitUntil { requestSequence == ["moderation:text"] }
        task.cancel()

        await #expect(throws: GenerationError.cancelled) { try await task.value }
        try await waitUntil { stub.stopLoadingCount >= 1 }
        #expect(requestSequence == ["moderation:text"])
    }
}

/// A Keychain that can't be read, for example a missing entitlement.
private struct UnreadableCredentialStore: CredentialStore {
    func load() throws -> String? { throw CredentialStoreError.keychain(-34018) }
    func save(_ key: String) throws {}
    func clear() throws {}
}
