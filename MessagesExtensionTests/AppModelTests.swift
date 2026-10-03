import Foundation
import Messages
import OpenMojiCore
import Testing

// `AppModel` transitions with fake services (tech spec §2, §10, §11), split
// into suites by area.

// A fake key on purpose: it must not look like `sk-...`.
private let fakeKey = "test-fake-key-0000"

private struct Rig {
    let model: AppModel
    let credentials: InMemoryCredentialStore
    let generator: FakeGenerator
}

@MainActor
private func makeRig(key: String? = fakeKey, prompt: String = defaultTestPrompt) -> Rig {
    let credentials = InMemoryCredentialStore(key: key)
    let generator = FakeGenerator()
    let model = AppModel(credentials: credentials, generator: generator)
    model.prompt = prompt
    return Rig(model: model, credentials: credentials, generator: generator)
}

@MainActor
private func inFlightTask(of model: AppModel) -> Task<Void, Never>? {
    if case .generating(let task) = model.state { return task }
    return nil
}

/// Waits for the in-flight generation, if any, to finish and be applied.
@MainActor
private func settle(_ model: AppModel) async {
    await inFlightTask(of: model)?.value
}

/// No key routes to Settings (FR-5).
@MainActor
struct AppModelKeyRoutingTests {
    @Test func startsInNeedsKeyWhenNoKeyIsStored() {
        #expect(makeRig(key: nil).model.state == .needsKey)
    }

    @Test func startsIdleWhenAKeyIsStored() {
        #expect(makeRig().model.state == .idle)
    }

    @Test func anUnreadableKeychainRoutesToNeedsKey() {
        let model = AppModel(credentials: UnreadableCredentialStore(), generator: FakeGenerator())
        #expect(model.state == .needsKey)
    }

    @Test func refreshingAfterTheKeyIsSavedMovesNeedsKeyToIdle() throws {
        let rig = makeRig(key: nil)
        try rig.credentials.save(fakeKey)
        rig.model.refreshKey()
        #expect(rig.model.state == .idle)
    }

    @Test func refreshingWithNoKeyStaysInNeedsKey() {
        let rig = makeRig(key: nil)
        rig.model.refreshKey()
        #expect(rig.model.state == .needsKey)
    }

    @Test func refreshingAfterTheKeyIsClearedRoutesToNeedsKey() throws {
        let rig = makeRig()
        try rig.credentials.clear()
        rig.model.refreshKey()
        #expect(rig.model.state == .needsKey)
    }

    @Test func refreshingWithAKeyLeavesIdlePreviewAndFailedAlone() async {
        let rig = makeRig()
        rig.model.refreshKey()
        #expect(rig.model.state == .idle)

        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)
        rig.model.refreshKey()
        #expect(rig.model.state == .preview(makeProcessedSticker()))

        await rig.generator.enqueue(.failure(.offline))
        rig.model.generate()
        await settle(rig.model)
        rig.model.refreshKey()
        #expect(rig.model.state == .failed(.offline, prompt: defaultTestPrompt))
    }

    @Test func clearingTheKeyMidGenerationAbandonsTheGeneration() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))

        try rig.credentials.clear()
        rig.model.refreshKey()
        #expect(rig.model.state == .needsKey)
        #expect(task.isCancelled)

        await rig.generator.release()
        await task.value
        #expect(rig.model.state == .needsKey)
    }

    @Test func generateWithoutAKeyDoesNothing() async {
        let rig = makeRig(key: nil)
        rig.model.generate()
        #expect(rig.model.state == .needsKey)
        #expect(await rig.generator.prompts.isEmpty)
    }
}

/// idle → generating → preview, and failures (FR-6, FR-11, FR-22, FR-23).
@MainActor
struct AppModelGenerationTests {
    @Test func generateMovesIdleToGeneratingThenPreview() async {
        let rig = makeRig(prompt: "a happy dog")
        let sticker = makeProcessedSticker(prompt: "a happy dog")
        await rig.generator.enqueue(.success(sticker), for: "a happy dog")

        rig.model.generate()
        #expect(inFlightTask(of: rig.model) != nil)

        await settle(rig.model)
        #expect(rig.model.state == .preview(sticker))
        #expect(await rig.generator.prompts == ["a happy dog"])
        #expect(rig.model.prompt == "a happy dog")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func aBlankPromptDoesNothing(prompt: String) async {
        let rig = makeRig(prompt: prompt)
        rig.model.generate()
        #expect(rig.model.state == .idle)
        #expect(await rig.generator.prompts.isEmpty)
    }

    @Test func generateWhileGeneratingIsIgnored() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))

        rig.model.generate()
        #expect(inFlightTask(of: rig.model) == task)

        await rig.generator.release()
        await task.value
        #expect(await rig.generator.prompts == [defaultTestPrompt])
        #expect(rig.model.state == .preview(makeProcessedSticker()))
    }

    @Test(arguments: [
        GenerationError.offline,
        .timeout,
        .invalidKey,
        .budgetExhausted,
        .rateLimited(retryAfter: 3),
        .contentRefused,
        .serviceUnavailable,
        .processingFailed,
    ])
    func aFailureKeepsThePromptAndShowsTheError(error: GenerationError) async {
        let rig = makeRig(prompt: "a sleepy owl")
        await rig.generator.enqueue(.failure(error), for: "a sleepy owl")

        rig.model.generate()
        await settle(rig.model)

        #expect(rig.model.state == .failed(error, prompt: "a sleepy owl"))
        #expect(rig.model.prompt == "a sleepy owl")
    }

    @Test func dismissingAnErrorReturnsToIdleWithThePromptIntact() async {
        let rig = makeRig(prompt: "a sleepy owl")
        await rig.generator.enqueue(.failure(.contentRefused), for: "a sleepy owl")
        rig.model.generate()
        await settle(rig.model)

        rig.model.dismissError()
        #expect(rig.model.state == .idle)
        #expect(rig.model.prompt == "a sleepy owl")
    }

    @Test func tryAgainFromFailedGeneratesAgain() async {
        let rig = makeRig()
        await rig.generator.enqueue(.failure(.timeout))
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.state == .failed(.timeout, prompt: defaultTestPrompt))

        rig.model.generate()
        #expect(inFlightTask(of: rig.model) != nil)
        await settle(rig.model)
        #expect(rig.model.state == .preview(makeProcessedSticker()))
        #expect(await rig.generator.prompts == [defaultTestPrompt, defaultTestPrompt])
    }

    @Test func aGeneratorThatThrowsCancelledReturnsToIdleWithoutAnError() async {
        let rig = makeRig()
        await rig.generator.enqueue(.failure(.cancelled))
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.state == .idle)
        #expect(rig.model.prompt == defaultTestPrompt)
    }
}

/// Cancel (FR-10) and `willResignActive`, which calls the same `cancel()`.
@MainActor
struct AppModelCancelTests {
    @Test func cancelReturnsToIdleWithNoErrorAndKeepsThePrompt() async throws {
        let rig = makeRig(prompt: "a brave fox")
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a brave fox")), for: "a brave fox")
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))

        rig.model.cancel()

        #expect(rig.model.state == .idle)
        #expect(rig.model.prompt == "a brave fox")
        #expect(task.isCancelled)

        await rig.generator.release()
        await task.value
    }

    @Test func aLateResultAfterCancelIsDropped() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))
        rig.model.cancel()

        await rig.generator.release()
        await task.value

        #expect(rig.model.state == .idle)
    }

    @Test func aLateFailureAfterCancelIsDropped() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.failure(.offline))
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))
        rig.model.cancel()

        await rig.generator.release()
        await task.value

        #expect(rig.model.state == .idle)
    }

    @Test func aCancelledGenerationCannotDisturbTheNextOne() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.hold("second")
        await rig.generator.enqueue(.failure(.offline))
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "second")), for: "second")
        rig.model.generate()
        let first = try #require(inFlightTask(of: rig.model))
        rig.model.cancel()

        rig.model.prompt = "second"
        rig.model.generate()
        let second = try #require(inFlightTask(of: rig.model))
        #expect(second != first)

        // The abandoned generation finishes while the new one is still in flight.
        await rig.generator.release()
        await first.value
        #expect(inFlightTask(of: rig.model) == second)

        await rig.generator.release("second")
        await second.value
        #expect(rig.model.state == .preview(makeProcessedSticker(prompt: "second")))
    }

    @Test func cancelOutsideGeneratingDoesNothing() async {
        let needsKey = makeRig(key: nil)
        needsKey.model.cancel()
        #expect(needsKey.model.state == .needsKey)

        let rig = makeRig()
        rig.model.cancel()
        #expect(rig.model.state == .idle)

        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)
        rig.model.cancel()
        #expect(rig.model.state == .preview(makeProcessedSticker()))

        await rig.generator.enqueue(.failure(.offline))
        rig.model.generate()
        await settle(rig.model)
        rig.model.cancel()
        #expect(rig.model.state == .failed(.offline, prompt: defaultTestPrompt))
    }
}

/// Preview, Regenerate (FR-11, FR-12) and the host's presentation style.
@MainActor
struct AppModelPreviewTests {
    @Test func dismissingThePreviewReturnsToIdle() async {
        let rig = makeRig()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)

        rig.model.dismissPreview()
        #expect(rig.model.state == .idle)
    }

    @Test func regenerateWithAnEditedPromptReplacesThePreview() async {
        let rig = makeRig()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.state == .preview(makeProcessedSticker()))

        rig.model.prompt = "a cat in a hat"
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a cat in a hat")), for: "a cat in a hat")
        rig.model.generate()
        #expect(inFlightTask(of: rig.model) != nil)
        await settle(rig.model)

        #expect(rig.model.state == .preview(makeProcessedSticker(prompt: "a cat in a hat")))
        #expect(await rig.generator.prompts == [defaultTestPrompt, "a cat in a hat"])
    }

    @Test func aFailedRegenerateKeepsTheEditedPrompt() async {
        let rig = makeRig()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)

        rig.model.prompt = "a cat in a hat"
        await rig.generator.enqueue(.failure(.serviceUnavailable), for: "a cat in a hat")
        rig.model.generate()
        await settle(rig.model)

        #expect(rig.model.state == .failed(.serviceUnavailable, prompt: "a cat in a hat"))
        #expect(rig.model.prompt == "a cat in a hat")
    }

    @Test func dismissPreviewAndDismissErrorIgnoreOtherStates() {
        let rig = makeRig()
        rig.model.dismissPreview()
        rig.model.dismissError()
        #expect(rig.model.state == .idle)

        let needsKey = makeRig(key: nil)
        needsKey.model.dismissPreview()
        needsKey.model.dismissError()
        #expect(needsKey.model.state == .needsKey)
    }

    @Test func presentationStyleStartsCompactAndFollowsTheHost() {
        let model = makeRig().model
        #expect(model.presentationStyle == .compact)
        model.presentationStyle = .expanded
        #expect(model.presentationStyle == .expanded)
    }
}
