import Foundation
import Security
import Testing
@testable import OpenMojiCore

/// Secret hygiene (tech spec §8 "Never logged", §11, NFR-6): no rendering of
/// an error, a result or a request mentions the API key or anything shaped
/// like one.
///
/// The sentinel is built at runtime, so no OpenAI-key-shaped literal sits in
/// the tree for gitleaks to find (ADR-0012). Every check looks for the exact
/// sentinel and for the `sk-` prefix: the sentinel stands in for a real key,
/// and `sk-` catches a key that reached a rendering in some other shape.
struct SecretHygieneTests {
    /// Shaped like a real project key (`sk-proj-...`), assembled from parts.
    private static let sentinel = ["sk", "proj", "HygieneSentinel", String(repeating: "x7Q", count: 12)]
        .joined(separator: "-")

    private static func leaks(_ text: String) -> Bool {
        text.contains(sentinel) || text.contains("sk-")
    }

    private func expectNoSecret(
        in texts: [String],
        _ subject: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for text in texts {
            #expect(!Self.leaks(text), "\(subject()) renders a key: \(text)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Renderings

    /// Every way a value turns into text.
    private static func texts(of value: Any) -> [String] {
        ["\(value)", String(describing: value), String(reflecting: value)]
    }

    /// Plus the `localizedDescription` and the `NSError` bridge, which is what
    /// Cocoa APIs and crash reporters see.
    private static func texts(ofError error: any Error) -> [String] {
        let bridged = error as NSError
        return texts(of: error) + [
            error.localizedDescription,
            String(describing: bridged),
            String(reflecting: bridged),
            String(describing: bridged.userInfo),
        ]
    }

    private static func texts(ofRequest request: URLRequest) -> [String] {
        texts(of: request) + [request.description, request.debugDescription, request.url?.absoluteString ?? ""]
    }

    private static func texts(ofTask task: URLSessionTask) -> [String] {
        texts(of: task) + [
            task.description,
            task.debugDescription,
            task.taskDescription ?? "",
            String(describing: task.originalRequest),
            String(describing: task.currentRequest),
        ]
    }

    // MARK: Every case, exhaustively

    /// Walks `next` from `first` until it returns `nil`. Each `next` below is
    /// a `switch` with no `default`: a new case stops this file compiling
    /// until it is added to the chain, so it can't skip the checks.
    private static func chain<T>(from first: T, _ next: (T) -> T?) -> [T] {
        var all = [first]
        while let item = next(all[all.count - 1]) {
            all.append(item)
        }
        return all
    }

    /// Every case, with and without its payload.
    private static var generationErrors: [GenerationError] {
        // One `case` per `GenerationError` case is the point of this switch.
        // swiftlint:disable:next cyclomatic_complexity
        func next(after error: GenerationError, message: String?, seconds: Int?) -> GenerationError? {
            switch error {
            case .cancelled: .offline
            case .offline: .timeout
            case .timeout: .invalidKey
            case .invalidKey: .keyNotPermitted(apiMessage: message)
            case .keyNotPermitted: .budgetExhausted
            case .budgetExhausted: .rateLimited(retryAfter: seconds)
            case .rateLimited: .contentRefused
            case .contentRefused: .modelUnavailable(apiMessage: message)
            case .modelUnavailable: .serviceUnavailable
            case .serviceUnavailable: .api(status: 400, apiMessage: message)
            case .api: .processingFailed
            case .processingFailed: nil
            }
        }
        return [(nil, nil), ("Check your plan.", 5)].flatMap { message, seconds in
            chain(from: GenerationError.cancelled) { next(after: $0, message: message, seconds: seconds) }
        }
    }

    private static var credentialStoreErrors: [CredentialStoreError] {
        chain(from: CredentialStoreError.keychain(errSecMissingEntitlement)) { error in
            switch error {
            case .keychain: .accessGroupUnavailable
            case .accessGroupUnavailable: .unreadableValue
            case .unreadableValue: nil
            }
        }
    }

    private static var keyValidationResults: [KeyValidationResult] {
        chain(from: KeyValidationResult.valid) { result in
            switch result {
            case .valid: .modelNotVisible
            case .modelNotVisible: .invalid
            case .invalid: .notPermitted
            case .notPermitted: .couldNotCheck
            case .couldNotCheck: nil
            }
        }
    }

    @Test func theLeakCheckCatchesTheSentinelAndThePrefix() {
        #expect(Self.leaks("Bearer \(Self.sentinel)"))
        #expect(Self.leaks("Incorrect API key provided: sk-proj-****abcd"))
        #expect(!Self.leaks("The OpenAI key isn't working. Check it in Settings."))
    }

    @Test func noGenerationErrorRendersAKey() {
        for error in Self.generationErrors {
            expectNoSecret(in: Self.texts(ofError: error) + [error.userMessage ?? ""], "\(error)")
        }
    }

    @Test func noCredentialStoreErrorRendersAKey() {
        for error in Self.credentialStoreErrors {
            expectNoSecret(in: Self.texts(ofError: error), "\(error)")
        }
    }

    @Test func noKeyValidationResultRendersAKey() {
        for result in Self.keyValidationResults {
            expectNoSecret(in: Self.texts(of: result), "\(result)")
        }
    }

    @Test func aStoreHoldingTheKeyDoesNotRenderIt() throws {
        let store = InMemoryCredentialStore(key: Self.sentinel)
        try store.save(Self.sentinel)
        expectNoSecret(in: Self.texts(of: store), "InMemoryCredentialStore")
    }

    // MARK: Requests

    /// What an in-flight request exposes to a description.
    private struct InFlight {
        let request: URLRequest
        let body: Data?
        let texts: [String]
    }

    /// Runs `operation` against a stub that never answers, waits until its
    /// request is in flight, and collects every text rendering reachable from
    /// the request the protocol saw and from the client's `URLSession` task.
    private func inFlight(_ operation: @escaping @Sendable (OpenAIClient) async -> Void) async throws -> InFlight {
        let stub = StubURLProtocol.Stub(.hang)
        let client = stub.makeClient()
        let running = Task { await operation(client) }

        let deadline = ContinuousClock.now + .seconds(5)
        while stub.recorded.isEmpty {
            try #require(ContinuousClock.now < deadline, "timed out waiting for the request")
            try await Task.sleep(for: .milliseconds(10))
        }

        let recorded = stub.recorded[0]
        var texts = Self.texts(ofRequest: recorded.request)
        for task in await client.session.allTasks {
            texts += Self.texts(ofTask: task)
        }
        running.cancel()
        await running.value
        return InFlight(request: recorded.request, body: recorded.body, texts: texts)
    }

    @Test func theGenerationRequestDoesNotRenderTheKey() async throws {
        let flight = try await inFlight { client in
            _ = try? await client.generate(prompt: "a happy cat", apiKey: Self.sentinel)
        }

        // The key really is on the request, in the header and nowhere else.
        #expect(flight.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.sentinel)")
        let body = try #require(flight.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("a happy cat"))
        expectNoSecret(in: [body], "the request body")

        expectNoSecret(in: flight.texts, "the generation request")
    }

    @Test func theValidationRequestDoesNotRenderTheKey() async throws {
        let flight = try await inFlight { client in
            _ = await client.validate(key: Self.sentinel)
        }

        #expect(flight.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.sentinel)")
        expectNoSecret(in: flight.texts, "the validation request")
    }

    // MARK: A key echoed by the API

    /// OpenAI's 401 text quotes the key it was given. Whatever status carries
    /// it, the error `generate` throws must not.
    @Test func aKeyEchoedByTheApiNeverReachesAThrownError() async {
        let echo = "Incorrect API key provided: \(Self.sentinel). You can find your API key at the OpenAI dashboard."
        let body = try! JSONSerialization.data(withJSONObject: [
            "error": ["message": echo, "type": "invalid_request_error", "code": "invalid_api_key"],
        ])
        // The statuses whose error can carry the API's message are redacted
        // rather than dropped, so the echo did reach the mapper.
        let carriesMessage: Set<Int> = [400, 403, 404]

        for status in [400, 401, 403, 404, 429, 500] {
            let stub = StubURLProtocol.Stub(.respond(status: status, body: body))
            do {
                _ = try await stub.makeClient().generate(prompt: "a happy cat", apiKey: Self.sentinel)
                Issue.record("status \(status) should have failed")
            } catch {
                expectNoSecret(in: Self.texts(ofError: error) + [error.userMessage ?? ""], "status \(status)")
                if carriesMessage.contains(status) {
                    #expect(error.userMessage?.contains("[redacted]") == true, "status \(status)")
                }
            }
        }
    }
}
