import Foundation
import OpenMojiCore
import Testing

// The library search filter (tech spec §10): a case- and diacritic-insensitive
// match on the prompt, mid-word, that keeps everything for an empty query.

private func prompts(_ stickers: [Sticker]) -> [String] {
    stickers.map(\.prompt)
}

struct StickerSearchTests {
    private let otter = makeSticker(prompt: "Happy otter holding a taco")
    private let beaver = makeSticker(prompt: "grumpy beaver")
    private let cafe = makeSticker(prompt: "a café on a rainy day")

    private var library: [Sticker] { [otter, beaver, cafe] }

    @Test func matchesRegardlessOfCase() {
        #expect(StickerSearch.filter(library, query: "OTTER") == [otter])
        #expect(StickerSearch.filter(library, query: "happy") == [otter])
        #expect(StickerSearch.filter(library, query: "GrUmPy") == [beaver])
    }

    @Test func matchesRegardlessOfAccents() {
        #expect(StickerSearch.filter(library, query: "cafe") == [cafe])
        #expect(StickerSearch.filter(library, query: "CAFÉ") == [cafe])
        let plain = makeSticker(prompt: "cafe latte")
        #expect(StickerSearch.filter([plain], query: "café") == [plain])
    }

    @Test func matchesInTheMiddleOfAWord() {
        #expect(StickerSearch.filter(library, query: "ott") == [otter])
        #expect(StickerSearch.filter(library, query: "ave") == [beaver])
        #expect(StickerSearch.filter(library, query: "ter hold") == [otter])
    }

    @Test func anEmptyQueryKeepsEveryStickerInOrder() {
        #expect(StickerSearch.filter(library, query: "") == library)
    }

    @Test func aWhitespaceOnlyQueryKeepsEveryStickerInOrder() {
        #expect(StickerSearch.filter(library, query: "   ") == library)
        #expect(StickerSearch.filter(library, query: " \n\t ") == library)
    }

    @Test func whitespaceAroundAQueryIsIgnored() {
        #expect(StickerSearch.filter(library, query: "  otter ") == [otter])
        #expect(StickerSearch.trimmed("  otter \n") == "otter")
    }

    @Test func noMatchGivesAnEmptyList() {
        #expect(StickerSearch.filter(library, query: "dragon").isEmpty)
    }

    @Test func matchesWordsNotMeaning() {
        // "otter" is not a synonym search: it does not find the beaver.
        #expect(prompts(StickerSearch.filter(library, query: "otter")) == ["Happy otter holding a taco"])
    }

    @Test func keepsTheOrderGivenWhenSeveralMatch() {
        let newer = makeSticker(prompt: "sleepy cat")
        let older = makeSticker(prompt: "grumpy cat")
        #expect(StickerSearch.filter([newer, older, beaver], query: "cat") == [newer, older])
    }

    @Test func anEmptyLibraryStaysEmpty() {
        #expect(StickerSearch.filter([], query: "otter").isEmpty)
        #expect(StickerSearch.filter([], query: "").isEmpty)
    }
}
