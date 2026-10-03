import Foundation
import OpenMojiCore

/// The prompt `AppModelTests` types unless a test says otherwise.
let defaultTestPrompt = "a cat"

/// A `StickerGenerating` that answers from per-prompt queues of canned results
/// and can be held mid-flight, so tests control exactly when a generation
/// finishes. Results and holds are keyed by prompt so two overlapping
/// generations are independent whatever order they run in.
///
/// It deliberately ignores task cancellation: a real generator might finish
/// anyway, and `AppModel` must drop that late result.
actor FakeGenerator: StickerGenerating {
    private(set) var prompts: [String] = []
    private var results: [String: [Result<ProcessedSticker, GenerationError>]] = [:]
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]

    func enqueue(_ result: Result<ProcessedSticker, GenerationError>, for prompt: String = defaultTestPrompt) {
        results[prompt, default: []].append(result)
    }

    /// Later `generate` calls for `prompt` suspend until `release(_:)`.
    func hold(_ prompt: String = defaultTestPrompt) {
        held.insert(prompt)
    }

    func release(_ prompt: String = defaultTestPrompt) {
        held.remove(prompt)
        for gate in gates.removeValue(forKey: prompt) ?? [] {
            gate.resume()
        }
    }

    func generate(prompt: String) async throws(GenerationError) -> ProcessedSticker {
        prompts.append(prompt)
        if held.contains(prompt) {
            await withCheckedContinuation { gates[prompt, default: []].append($0) }
        }
        guard let result = results[prompt]?.first else {
            throw .api(status: -1, apiMessage: "FakeGenerator had no result queued for \"\(prompt)\"")
        }
        results[prompt]?.removeFirst()
        return try result.get()
    }
}

/// A Keychain that can't be read, for example a missing entitlement.
struct UnreadableCredentialStore: CredentialStore {
    func load() throws -> String? {
        throw CredentialStoreError.keychain(-34018)
    }

    func save(_ key: String) throws {}
    func clear() throws {}
}

func makeProcessedSticker(prompt: String = defaultTestPrompt) -> ProcessedSticker {
    ProcessedSticker(
        prompt: prompt,
        modelID: "fake-model",
        quality: "low",
        png: Data([0x89, 0x50, 0x4E, 0x47]),
        edge: 300
    )
}
