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
    let model = AppModel(credentials: credentials, generator: generator, library: FakeLibrary())
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

/// No key routes to needs-key, the library with "Set up OpenMoji" (FR-5).
@MainActor
struct AppModelKeyRoutingTests {
    @Test func startsInNeedsKeyWhenNoKeyIsStored() {
        #expect(makeRig(key: nil).model.state == .needsKey)
    }

    @Test func startsIdleWhenAKeyIsStored() {
        #expect(makeRig().model.state == .idle)
    }

    @Test func anUnreadableKeychainRoutesToNeedsKey() {
        let model = AppModel(credentials: UnreadableCredentialStore(), generator: FakeGenerator(), library: FakeLibrary())
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

/// Counts how often the model asks the host for the expanded style.
@MainActor
private final class ExpandRequests {
    private(set) var count = 0
    func record() { count += 1 }
}

/// What the root view shows for a key and a presentation style (tech spec §8
/// Routing, §10; FR-5, NFR-10, ADR-0017). `refreshKey()` is what
/// `willBecomeActive` calls.
@MainActor
struct AppModelRouteTests {
    @Test func noKeyInCompactShowsTheLibraryWithSetUp() {
        let model = makeRig(key: nil).model
        model.presentationStyle = .compact
        #expect(model.state == .needsKey)
        #expect(model.route == .compactSetUp)
    }

    @Test func noKeyInExpandedShowsTheLibraryWithSetUpNotSettingsOrCompose() {
        let model = makeRig(key: nil).model
        model.presentationStyle = .expanded
        #expect(model.state == .needsKey)
        #expect(model.route == .librarySetUp)
    }

    @Test func anUnreadableKeychainRoutesLikeNoKey() {
        let model = AppModel(credentials: UnreadableCredentialStore(), generator: FakeGenerator(), library: FakeLibrary())
        #expect(model.route == .compactSetUp)
        model.presentationStyle = .expanded
        #expect(model.route == .librarySetUp)
    }

    @Test func aKeyInCompactShowsTheLibraryWithNewSticker() {
        let model = makeRig().model
        model.presentationStyle = .compact
        #expect(model.route == .compactHome)
    }

    @Test func aKeyInExpandedLandsOnTheLibraryNotCompose() {
        let model = makeRig().model
        model.presentationStyle = .expanded
        #expect(model.state == .idle)
        #expect(model.route == .library)
    }

    @Test func theRouteFollowsThePresentationStyle() {
        let model = makeRig(key: nil).model
        model.presentationStyle = .expanded
        #expect(model.route == .librarySetUp)
        model.presentationStyle = .compact
        #expect(model.route == .compactSetUp)
    }

    @Test func setUpRequestsTheExpandedStyle() {
        let model = makeRig(key: nil).model
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }

        model.startSetUp()
        #expect(requests.count == 1)
        // Still no key: the route only changes once the host reports expanded.
        #expect(model.state == .needsKey)
        #expect(model.route == .compactSetUp)

        model.presentationStyle = .expanded
        #expect(model.route == .librarySetUp)
    }

    @Test func setUpIsSafeBeforeTheHostSetsTheRequest() {
        makeRig(key: nil).model.startSetUp()
    }

    @Test(arguments: [MSMessagesAppPresentationStyle.compact, .expanded])
    func becomingActiveAfterAKeyWasSavedMeanwhileLeavesSetUp(style: MSMessagesAppPresentationStyle) throws {
        let rig = makeRig(key: nil)
        rig.model.presentationStyle = style
        try rig.credentials.save(fakeKey)

        rig.model.refreshKey()
        #expect(rig.model.route == (style == .expanded ? .library : .compactHome))
    }

    @Test(arguments: [MSMessagesAppPresentationStyle.compact, .expanded])
    func becomingActiveAfterTheKeyWasClearedMeanwhileRoutesToSetUp(style: MSMessagesAppPresentationStyle) throws {
        let rig = makeRig()
        rig.model.presentationStyle = style
        try rig.credentials.clear()

        rig.model.refreshKey()
        #expect(rig.model.route == (style == .expanded ? .librarySetUp : .compactSetUp))
    }

    @Test func becomingActiveWithNothingChangedKeepsTheRoute() {
        let withKey = makeRig().model
        withKey.presentationStyle = .expanded
        withKey.refreshKey()
        #expect(withKey.route == .library)

        let noKey = makeRig(key: nil).model
        noKey.presentationStyle = .expanded
        noKey.refreshKey()
        #expect(noKey.route == .librarySetUp)
    }

    @Test func newStickerOpensComposeWhenExpandedWithoutAskingForTheStyle() {
        let model = makeRig().model
        model.presentationStyle = .expanded
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }
        #expect(model.route == .library)

        model.startNewSticker()
        #expect(model.route == .compose)
        #expect(model.state == .idle)
        #expect(requests.count == 0)
    }

    @Test func newStickerInCompactAsksToExpandAndComposeShowsOnceExpanded() {
        let model = makeRig().model
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }

        model.startNewSticker()
        #expect(requests.count == 1)
        #expect(model.route == .compactHome)

        model.presentationStyle = .expanded
        #expect(model.route == .compose)
    }

    @Test func backFromComposeReturnsToTheLibraryWithThePromptKept() {
        let model = makeRig(prompt: "a brave fox").model
        model.presentationStyle = .expanded
        model.startNewSticker()
        #expect(model.route == .compose)

        model.closeCompose()
        #expect(model.route == .library)
        #expect(model.prompt == "a brave fox")

        model.startNewSticker()
        #expect(model.route == .compose)
    }

    @Test func backOnlyActsFromThePrompt() async throws {
        let rig = makeRig(prompt: "a brave fox")
        rig.model.presentationStyle = .expanded
        await rig.generator.hold("a brave fox")
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a brave fox")), for: "a brave fox")
        rig.model.startNewSticker()
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))

        rig.model.closeCompose()
        #expect(rig.model.route == .generating)

        await rig.generator.release("a brave fox")
        await task.value
        rig.model.closeCompose()
        #expect(rig.model.route == .preview)
    }

    @Test func aGenerationCancelledOrFailedLandsBackOnComposeNotTheLibrary() async throws {
        let rig = makeRig(prompt: "a brave fox")
        rig.model.presentationStyle = .expanded
        await rig.generator.hold("a brave fox")
        await rig.generator.enqueue(.failure(.offline), for: "a brave fox")
        rig.model.startNewSticker()
        rig.model.generate()
        let abandoned = try #require(inFlightTask(of: rig.model))
        rig.model.cancel()
        #expect(rig.model.route == .compose)

        await rig.generator.release("a brave fox")
        await abandoned.value
        await rig.generator.enqueue(.failure(.offline), for: "a brave fox")
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.route == .failed(.offline))
        rig.model.dismissError()
        #expect(rig.model.route == .compose)
    }

    @Test func clearingTheKeyWhileComposingLeavesComposeAndSavingOneReturnsToTheLibrary() throws {
        let rig = makeRig()
        rig.model.presentationStyle = .expanded
        rig.model.startNewSticker()
        #expect(rig.model.route == .compose)

        try rig.credentials.clear()
        rig.model.refreshKey()
        #expect(rig.model.route == .librarySetUp)

        try rig.credentials.save(fakeKey)
        rig.model.refreshKey()
        #expect(rig.model.route == .library)
    }

    @Test(arguments: [MSMessagesAppPresentationStyle.compact, .expanded])
    func generatingPreviewAndErrorRouteTheSameInBothStyles(style: MSMessagesAppPresentationStyle) async {
        let rig = makeRig()
        rig.model.presentationStyle = style
        await rig.generator.enqueue(.failure(.serviceUnavailable))

        rig.model.generate()
        #expect(rig.model.route == .generating)
        await settle(rig.model)
        #expect(rig.model.route == .failed(.serviceUnavailable))

        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.route == .preview)
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

    /// The 90 s timeout (NFR-4) reaches the model as `.timeout`: the client's
    /// `URLError.timedOut` is mapped in `OpenMojiCoreTests`. A held fake stands
    /// in for the wait, so the test doesn't take 90 s.
    @Test func aTimeoutAfterWaitingSurfacesAsTimeoutAndKeepsThePrompt() async throws {
        let rig = makeRig(prompt: "a sleepy owl")
        await rig.generator.hold("a sleepy owl")
        await rig.generator.enqueue(.failure(.timeout), for: "a sleepy owl")
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))
        #expect(rig.model.route == .generating)

        await rig.generator.release("a sleepy owl")
        await task.value

        #expect(rig.model.state == .failed(.timeout, prompt: "a sleepy owl"))
        #expect(rig.model.route == .failed(.timeout))
        #expect(rig.model.prompt == "a sleepy owl")
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

    /// Cancel on the Generating view lands on the style's home (Compose when
    /// expanded, "New sticker" when compact), never on the error route, even
    /// when the abandoned request goes on to fail.
    @Test(arguments: [MSMessagesAppPresentationStyle.compact, .expanded])
    func cancelLeavesGeneratingForTheHomeRouteWithNoError(style: MSMessagesAppPresentationStyle) async throws {
        let home: AppModel.Route = style == .expanded ? .compose : .compactHome
        let rig = makeRig(prompt: "a brave fox")
        rig.model.presentationStyle = style
        await rig.generator.hold("a brave fox")
        await rig.generator.enqueue(.failure(.offline), for: "a brave fox")
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))
        #expect(rig.model.route == .generating)

        rig.model.cancel()
        #expect(rig.model.route == home)
        #expect(rig.model.prompt == "a brave fox")

        await rig.generator.release("a brave fox")
        await task.value
        #expect(rig.model.route == home)
        #expect(rig.model.prompt == "a brave fox")
    }

    /// `willResignActive` calls `cancel()` and `willBecomeActive` calls
    /// `refreshKey()` (`MessagesViewController`, which a test can't import).
    @Test func resigningMidGenerationAbandonsItAndTheNextActivationStartsAtThePrompt() async throws {
        let rig = makeRig(prompt: "a brave fox")
        rig.model.presentationStyle = .expanded
        await rig.generator.hold("a brave fox")
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a brave fox")), for: "a brave fox")
        rig.model.generate()
        let task = try #require(inFlightTask(of: rig.model))

        rig.model.cancel()  // willResignActive
        #expect(task.isCancelled)
        #expect(rig.model.state == .idle)

        rig.model.refreshKey()  // willBecomeActive
        #expect(rig.model.route == .compose)
        #expect(rig.model.prompt == "a brave fox")

        // The abandoned request finishing late changes nothing.
        await rig.generator.release("a brave fox")
        await task.value
        #expect(rig.model.state == .idle)

        // And a new generation works.
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a brave fox")), for: "a brave fox")
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.state == .preview(makeProcessedSticker(prompt: "a brave fox")))
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

/// One entry per `GenerationError` case, so the error-state tests cover every
/// case. `init(_:)` and `sample` switch exhaustively: a new `GenerationError`
/// case fails to compile here until it has a kind and a sample, and is then
/// picked up by every test below that takes `ErrorKind.allCases`.
enum ErrorKind: CaseIterable {
    case cancelled
    case offline
    case timeout
    case invalidKey
    case keyNotPermitted
    case budgetExhausted
    case rateLimitedWithSeconds
    case rateLimitedWithoutSeconds
    case contentRefused
    case modelUnavailable
    case serviceUnavailable
    case api
    case processingFailed

    // One case per error case is the point of this switch.
    // swiftlint:disable:next cyclomatic_complexity
    init(_ error: GenerationError) {
        switch error {
        case .cancelled: self = .cancelled
        case .offline: self = .offline
        case .timeout: self = .timeout
        case .invalidKey: self = .invalidKey
        case .keyNotPermitted: self = .keyNotPermitted
        case .budgetExhausted: self = .budgetExhausted
        case .rateLimited(let seconds):
            self = seconds == nil ? .rateLimitedWithoutSeconds : .rateLimitedWithSeconds
        case .contentRefused: self = .contentRefused
        case .modelUnavailable: self = .modelUnavailable
        case .serviceUnavailable: self = .serviceUnavailable
        case .api: self = .api
        case .processingFailed: self = .processingFailed
        }
    }

    var sample: GenerationError {
        switch self {
        case .cancelled: .cancelled
        case .offline: .offline
        case .timeout: .timeout
        case .invalidKey: .invalidKey
        case .keyNotPermitted: .keyNotPermitted(apiMessage: "Project lacks image access.")
        case .budgetExhausted: .budgetExhausted
        case .rateLimitedWithSeconds: .rateLimited(retryAfter: 3)
        case .rateLimitedWithoutSeconds: .rateLimited(retryAfter: nil)
        case .contentRefused: .contentRefused
        case .modelUnavailable: .modelUnavailable(apiMessage: "No such model.")
        case .serviceUnavailable: .serviceUnavailable
        case .api: .api(status: 418, apiMessage: "Teapot.")
        case .processingFailed: .processingFailed
        }
    }
}

private let bothStyles: [MSMessagesAppPresentationStyle] = [.compact, .expanded]
private let failingKinds = ErrorKind.allCases.filter { $0 != .cancelled }

/// The Error state (FR-22 to FR-24; tech spec §6, §10).
///
/// "The library is never touched" (FR-24) holds by construction, not by a fake:
/// `AppModel` takes only a credential store and a generator, so no
/// `LibraryStore` write is reachable from the failure path. Keep, the only
/// write, takes a `ProcessedSticker`, which a failed generation never produces.
@MainActor
struct AppModelErrorStateTests {
    private static let prompt = "a sleepy owl"

    /// A rig whose first generation of `prompt` fails with `error`.
    private func failedRig(
        _ error: GenerationError,
        style: MSMessagesAppPresentationStyle = .expanded
    ) async -> Rig {
        let rig = makeRig(prompt: Self.prompt)
        rig.model.presentationStyle = style
        await rig.generator.enqueue(.failure(error), for: Self.prompt)
        rig.model.generate()
        await settle(rig.model)
        return rig
    }

    @Test(arguments: ErrorKind.allCases)
    func everyKindMapsToItsOwnSample(kind: ErrorKind) {
        #expect(ErrorKind(kind.sample) == kind)
    }

    @Test(arguments: ErrorKind.allCases, bothStyles)
    func aFailureShowsOneMessageAndKeepsThePrompt(kind: ErrorKind, style: MSMessagesAppPresentationStyle) async {
        let error = kind.sample
        let rig = await failedRig(error, style: style)

        if kind == .cancelled {
            // No message and no error view: back at the prompt, as for Cancel.
            #expect(error.userMessage == nil)
            #expect(rig.model.state == .idle)
            #expect(rig.model.route == (style == .expanded ? .compose : .compactHome))
        } else {
            #expect(error.userMessage?.isEmpty == false)
            #expect(rig.model.state == .failed(error, prompt: Self.prompt))
            #expect(rig.model.route == .failed(error))
        }
        #expect(rig.model.prompt == Self.prompt)
        #expect(await rig.generator.prompts == [Self.prompt])
    }

    @Test(arguments: failingKinds)
    func tryAgainSendsTheSamePromptAndAFurtherFailureKeepsIt(kind: ErrorKind) async {
        let error = kind.sample
        let rig = await failedRig(error)
        #expect(rig.model.canGenerate)

        // Try again is `generate()`: it leaves failed for generating.
        await rig.generator.enqueue(.failure(error), for: Self.prompt)
        rig.model.generate()
        #expect(inFlightTask(of: rig.model) != nil)
        await settle(rig.model)
        #expect(rig.model.state == .failed(error, prompt: Self.prompt))
        #expect(rig.model.prompt == Self.prompt)

        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: Self.prompt)), for: Self.prompt)
        rig.model.generate()
        await settle(rig.model)
        #expect(rig.model.state == .preview(makeProcessedSticker(prompt: Self.prompt)))
        #expect(await rig.generator.prompts == [Self.prompt, Self.prompt, Self.prompt])
    }

    @Test(arguments: failingKinds, bothStyles)
    func editingReturnsToTheHomeRouteWithThePromptIntact(kind: ErrorKind, style: MSMessagesAppPresentationStyle) async {
        let rig = await failedRig(kind.sample, style: style)

        rig.model.dismissError()
        #expect(rig.model.state == .idle)
        #expect(rig.model.route == (style == .expanded ? .compose : .compactHome))
        #expect(rig.model.prompt == Self.prompt)
    }

    /// Only a rejected key points at Settings (§6). Everything else, including
    /// `.keyNotPermitted`, which the table gives no Settings button, does not.
    @Test(arguments: ErrorKind.allCases)
    func onlyInvalidKeyOffersSettings(kind: ErrorKind) async {
        #expect(kind.sample.offersSettings == (kind == .invalidKey))
    }

    @Test func invalidKeyFailsToTheErrorRouteWithSettingsOffered() async {
        let rig = await failedRig(.invalidKey)

        guard case .failed(let error) = rig.model.route else {
            Issue.record("expected the failed route, got \(rig.model.route)")
            return
        }
        #expect(error.offersSettings)
        #expect(error.userMessage?.contains("Settings") == true)
    }
}
