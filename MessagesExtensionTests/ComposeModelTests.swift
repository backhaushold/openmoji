import Foundation
import OpenMojiCore
import Testing

// Compose behaviour in `AppModel` (tech spec §10, FR-6): the 200-character
// prompt limit and counter, when Generate is enabled, and compact's
// "New sticker".

@MainActor
private func makeModel(key: String? = "test-fake-key-0000", prompt: String = "") -> AppModel {
    let model = AppModel(credentials: InMemoryCredentialStore(key: key), generator: FakeGenerator(), library: FakeLibrary())
    model.prompt = prompt
    return model
}

/// Counts how often the model asks the host for the expanded style.
@MainActor
private final class ExpandRequests {
    private(set) var count = 0
    func record() { count += 1 }
}

/// FR-6: the prompt never holds more than 200 characters, counted as
/// `Character`s (extended grapheme clusters), the unit the user sees.
@MainActor
struct PromptLimitTests {
    private let limit = AppModel.promptLimit

    @Test func theLimitIs200() {
        #expect(limit == 200)
    }

    @Test func aPromptUnderTheLimitIsKeptAsTyped() {
        let model = makeModel()
        model.prompt = "grumpy cat"
        #expect(model.prompt == "grumpy cat")
    }

    @Test func aPromptOfExactlyTheLimitIsKept() {
        let model = makeModel()
        let text = String(repeating: "a", count: limit)
        model.prompt = text
        #expect(model.prompt == text)
    }

    @Test func aPasteOverTheLimitIsTruncatedToIt() {
        let model = makeModel()
        let pasted = String(repeating: "a", count: limit) + String(repeating: "b", count: 50)
        model.prompt = pasted
        #expect(model.prompt == String(repeating: "a", count: limit))
    }

    @Test func typingPastTheLimitIsRefused() {
        let model = makeModel(prompt: String(repeating: "a", count: limit))
        model.prompt += "b"
        #expect(model.prompt == String(repeating: "a", count: limit))
    }

    @Test func editingDownFromTheLimitWorksAgain() {
        let model = makeModel(prompt: String(repeating: "a", count: limit))
        model.prompt.removeLast()
        model.prompt += "b"
        #expect(model.prompt == String(repeating: "a", count: limit - 1) + "b")
    }

    @Test func emojiCountOnceEach() {
        let model = makeModel()
        model.prompt = String(repeating: "🐸", count: limit + 10)
        #expect(model.prompt == String(repeating: "🐸", count: limit))
    }

    @Test func aZWJFamilyEmojiIsOneCharacterSoItFitsWhereUTF16WouldNot() {
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1)
        #expect(family.utf16.count > 1)
        let model = makeModel()
        model.prompt = String(repeating: family, count: limit)
        #expect(model.prompt.count == limit)
        #expect(model.prompt == String(repeating: family, count: limit))
    }

    @Test func truncationNeverSplitsAGraphemeCluster() {
        // The 201st character is a ZWJ family: it is dropped whole, not cut
        // into its parts.
        let model = makeModel()
        model.prompt = String(repeating: "a", count: limit) + "👨‍👩‍👧‍👦"
        #expect(model.prompt == String(repeating: "a", count: limit))

        // The 200th is one: it is kept whole.
        model.prompt = String(repeating: "a", count: limit - 1) + "👨‍👩‍👧‍👦" + "zzz"
        #expect(model.prompt == String(repeating: "a", count: limit - 1) + "👨‍👩‍👧‍👦")
    }

    @Test func skinToneAndFlagEmojiAreOneCharacterEach() {
        let model = makeModel()
        model.prompt = String(repeating: "👍🏽🇳🇿", count: limit)
        #expect(model.prompt.count == limit)
        #expect(model.prompt == String(repeating: "👍🏽🇳🇿", count: limit / 2))
    }

    @Test func aCombiningAccentCountsWithItsLetter() {
        let decomposed = "e\u{301}"
        let model = makeModel()
        model.prompt = String(repeating: decomposed, count: limit + 5)
        #expect(model.prompt.count == limit)
    }

    @Test func aCRLFLineBreakIsOneCharacter() {
        let model = makeModel()
        model.prompt = String(repeating: "\r\n", count: limit + 5)
        #expect(model.prompt.count == limit)
    }

    @Test func theLimitAlsoHoldsInPreview() async {
        // The prompt is one shared draft (FR-12), so Preview's editable
        // prompt has the same limit.
        let generator = FakeGenerator()
        await generator.enqueue(.success(makeProcessedSticker()), for: "a cat")
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "a cat"
        model.generate()
        if case .generating(let task) = model.state { await task.value }
        guard case .preview = model.state else {
            Issue.record("expected preview, got \(model.state)")
            return
        }
        model.prompt = String(repeating: "x", count: limit + 1)
        #expect(model.prompt.count == limit)
    }
}

/// The counter shows how many characters the prompt has, out of the limit.
@MainActor
struct PromptCounterTests {
    @Test func countsZeroForAnEmptyPrompt() {
        #expect(makeModel().promptCount == 0)
    }

    @Test func countsCharactersAsTheUserTypes() {
        let model = makeModel()
        model.prompt = "a cat"
        #expect(model.promptCount == 5)
        model.prompt += "s"
        #expect(model.promptCount == 6)
        model.prompt.removeLast(3)
        #expect(model.promptCount == 3)
    }

    @Test func countsEmojiByCharacterNotByCodeUnit() {
        let model = makeModel(prompt: "🐸☕️")
        #expect(model.promptCount == 2)
    }

    @Test func stopsAtTheLimitForALongPaste() {
        let model = makeModel(prompt: String(repeating: "a", count: 500))
        #expect(model.promptCount == AppModel.promptLimit)
    }

    @Test func whitespaceCounts() {
        #expect(makeModel(prompt: "   ").promptCount == 3)
    }
}

/// Generate is enabled only for a real prompt in a state that can generate.
@MainActor
struct CanGenerateTests {
    @Test func isDisabledForAnEmptyPrompt() {
        #expect(!makeModel(prompt: "").canGenerate)
    }

    @Test(arguments: [" ", "     ", "\n", "\t", " \n\t ", "\u{00A0}"])
    func isDisabledForAWhitespaceOnlyPrompt(_ whitespace: String) {
        #expect(!makeModel(prompt: whitespace).canGenerate)
    }

    @Test func isEnabledForARealPrompt() {
        #expect(makeModel(prompt: "a cat").canGenerate)
    }

    @Test func isEnabledForAPromptWithSurroundingWhitespace() {
        #expect(makeModel(prompt: "  a cat \n").canGenerate)
    }

    @Test func isEnabledForAnEmojiOnlyPrompt() {
        #expect(makeModel(prompt: "🐸☕️").canGenerate)
    }

    @Test func followsThePromptAsItIsEdited() {
        let model = makeModel()
        #expect(!model.canGenerate)
        model.prompt = "a"
        #expect(model.canGenerate)
        model.prompt = "  "
        #expect(!model.canGenerate)
    }

    @Test func isDisabledWithoutAKey() {
        let model = makeModel(key: nil, prompt: "a cat")
        #expect(model.state == .needsKey)
        #expect(!model.canGenerate)
    }

    @Test func isDisabledWhileGenerating() async {
        let generator = FakeGenerator()
        await generator.hold("a cat")
        await generator.enqueue(.success(makeProcessedSticker()), for: "a cat")
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "a cat"
        #expect(model.canGenerate)

        model.generate()
        guard case .generating(let task) = model.state else {
            Issue.record("expected generating, got \(model.state)")
            return
        }
        #expect(!model.canGenerate)

        await generator.release("a cat")
        await task.value
    }

    @Test func isEnabledAgainAfterACancel() async {
        let generator = FakeGenerator()
        await generator.hold("a cat")
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "a cat"
        model.generate()
        #expect(!model.canGenerate)

        model.cancel()
        #expect(model.state == .idle)
        #expect(model.canGenerate)
        await generator.release("a cat")
    }

    @Test func generateDoesNothingWhenItIsDisabled() async {
        let generator = FakeGenerator()
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "   "
        model.generate()
        #expect(model.state == .idle)
        #expect(await generator.prompts.isEmpty)
    }
}

/// Compact has no text field: "New sticker" asks the host to expand.
@MainActor
struct NewStickerTests {
    @Test func requestsTheExpandedStyle() {
        let model = makeModel()
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }

        model.startNewSticker()
        #expect(requests.count == 1)
    }

    @Test func requestsAgainOnEachTap() {
        let model = makeModel()
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }

        model.startNewSticker()
        model.startNewSticker()
        #expect(requests.count == 2)
    }

    @Test func doesNothingUntilTheHostSetsTheRequest() {
        // The default request is a no-op, so a model with no host is safe.
        makeModel().startNewSticker()
    }

    @Test func leavesTheStateAndPromptAlone() {
        let model = makeModel(prompt: "a cat")
        model.requestExpandedStyle = {}
        model.startNewSticker()
        #expect(model.state == .idle)
        #expect(model.prompt == "a cat")
    }
}

/// FR-21: "Reuse prompt" on a library cell opens Compose with that sticker's
/// prompt as the draft, to edit and generate from.
@MainActor
struct ReusePromptTests {
    @Test func opensComposeWithTheStickersPromptAsTheDraft() {
        let model = makeModel()
        model.presentationStyle = .expanded
        #expect(model.route == .library)

        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(model.route == .compose)
        #expect(model.prompt == "grumpy cat")
        #expect(model.promptCount == 10)
        #expect(model.canGenerate)
        #expect(model.state == .idle)
    }

    @Test func replacesTheDraftThatWasThere() {
        let model = makeModel(prompt: "half typed")
        model.presentationStyle = .expanded
        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(model.prompt == "grumpy cat")
    }

    @Test func theReusedPromptCanBeEditedLikeAnyOther() {
        let model = makeModel()
        model.presentationStyle = .expanded
        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        model.prompt += " in a hat"
        #expect(model.prompt == "grumpy cat in a hat")
    }

    @Test func aPromptAtTheLimitComesInWhole() {
        let text = String(repeating: "a", count: AppModel.promptLimit)
        let model = makeModel()
        model.presentationStyle = .expanded
        model.reusePrompt(of: makeSticker(prompt: text))
        #expect(model.prompt == text)
    }

    @Test func fromCompactItSetsThePromptAndAsksTheHostToExpand() {
        let model = makeModel()
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }
        #expect(model.route == .compactHome)

        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(requests.count == 1)
        #expect(model.prompt == "grumpy cat")

        // Compose shows once the host reports the expanded style, as for "New sticker".
        model.presentationStyle = .expanded
        #expect(model.route == .compose)
    }

    @Test func withNoKeyItDoesNothingAndALaterKeyLandsOnTheLibrary() {
        let model = makeModel(key: nil, prompt: "a cat")
        let requests = ExpandRequests()
        model.requestExpandedStyle = { requests.record() }
        model.presentationStyle = .expanded
        #expect(model.route == .librarySetUp)

        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(model.route == .librarySetUp)
        #expect(!model.isComposing)
        #expect(model.prompt == "a cat")
        #expect(requests.count == 0)
    }

    @Test func whileGeneratingItLeavesTheDraftAlone() async {
        let generator = FakeGenerator()
        await generator.hold("a cat")
        await generator.enqueue(.success(makeProcessedSticker()), for: "a cat")
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "a cat"
        model.generate()
        guard case .generating(let task) = model.state else {
            Issue.record("expected generating, got \(model.state)")
            return
        }

        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(model.prompt == "a cat")

        await generator.release("a cat")
        await task.value
    }

    @Test func inPreviewItLeavesTheDraftAlone() async {
        let generator = FakeGenerator()
        await generator.enqueue(.success(makeProcessedSticker()), for: "a cat")
        let model = AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: generator, library: FakeLibrary())
        model.prompt = "a cat"
        model.generate()
        if case .generating(let task) = model.state { await task.value }
        guard case .preview = model.state else {
            Issue.record("expected preview, got \(model.state)")
            return
        }

        model.reusePrompt(of: makeSticker(prompt: "grumpy cat"))
        #expect(model.prompt == "a cat")
    }
}
