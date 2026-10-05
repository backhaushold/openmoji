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

/// A `StickerLibrary` over an in-memory list, which can fail its reads or hold
/// one mid-flight, so tests control exactly when a read finishes. A read
/// returns the list as it was when the read started, and fails or not as
/// `failReads` was when it started. Keep can be failed or held
/// the same way, and every call to it is counted, so a test can assert that
/// nothing wrote (FR-24). Delete can be failed and is recorded.
actor FakeLibrary: StickerLibrary {
    struct ReadFailure: Error {}
    struct KeepFailure: Error {}
    struct DeleteFailure: Error {}

    private var stored: [Sticker]
    private var failing = false
    private var held = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0

    private var failingKeeps = false
    private var keepHeld = false
    private var keepGate: CheckedContinuation<Void, Never>?
    /// Every `keep` call, including a failed one.
    private(set) var keepAttempts = 0
    /// What the successful `keep` calls were given, in order.
    private(set) var kept: [ProcessedSticker] = []

    private var failingDeletes = false
    /// Every `delete` call, including a failed one.
    private(set) var deleteAttempts = 0
    /// The ids the successful `delete` calls were given, in order.
    private(set) var deleted: [UUID] = []

    init(stickers: [Sticker] = []) {
        stored = stickers
    }

    func set(_ stickers: [Sticker]) {
        stored = stickers
    }

    func failReads(_ failing: Bool) {
        self.failing = failing
    }

    /// The next `stickers()` suspends until `release()`.
    func hold() {
        held = true
    }

    func release() {
        held = false
        gate?.resume()
        gate = nil
    }

    func failKeeps(_ failing: Bool) {
        failingKeeps = failing
    }

    /// The next `keep(_:)` suspends until `releaseKeeps()`.
    func holdKeeps() {
        keepHeld = true
    }

    func releaseKeeps() {
        keepHeld = false
        keepGate?.resume()
        keepGate = nil
    }

    /// Like the real store: the new sticker goes first, and a failure leaves
    /// the list as it was.
    func keep(_ processed: ProcessedSticker) async throws {
        keepAttempts += 1
        if keepHeld {
            await withCheckedContinuation { keepGate = $0 }
        }
        if failingKeeps { throw KeepFailure() }
        kept.append(processed)
        stored.insert(
            Sticker(
                id: UUID(),
                prompt: processed.prompt,
                createdAt: Date(),
                modelID: processed.modelID,
                quality: processed.quality,
                pixelSize: processed.edge,
                byteCount: processed.png.count
            ),
            at: 0
        )
    }

    func failDeletes(_ failing: Bool) {
        failingDeletes = failing
    }

    /// Like the real store: the sticker goes, the others stay in order, an
    /// unknown id changes nothing, and a failure leaves the list as it was.
    func delete(_ id: UUID) async throws {
        deleteAttempts += 1
        if failingDeletes { throw DeleteFailure() }
        deleted.append(id)
        stored.removeAll { $0.id == id }
    }

    func stickers() async throws -> [Sticker] {
        readCount += 1
        let snapshot = stored
        let fails = failing
        if held {
            held = false
            await withCheckedContinuation { gate = $0 }
        }
        if fails { throw ReadFailure() }
        return snapshot
    }

    nonisolated func fileURL(for sticker: Sticker) -> URL {
        URL(fileURLWithPath: "/fake-library").appendingPathComponent(sticker.fileName)
    }
}

func makeSticker(prompt: String = defaultTestPrompt, createdAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> Sticker {
    Sticker(
        id: UUID(),
        prompt: prompt,
        createdAt: createdAt,
        modelID: "fake-model",
        quality: "low",
        pixelSize: 300,
        byteCount: 4
    )
}
