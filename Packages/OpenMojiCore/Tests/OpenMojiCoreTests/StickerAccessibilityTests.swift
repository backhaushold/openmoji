import Foundation
import Testing
@testable import OpenMojiCore

@Suite struct StickerAccessibilityTests {
    // MARK: ASCII prompt truncation

    @Test func truncatesASCIIPromptAt150Scalars() {
        let prompt = String(repeating: "a", count: 160)
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count == 150)
        #expect(accessibilityText == String(repeating: "a", count: 150))
    }

    @Test func preservesASCIIPromptUnder150Scalars() {
        let prompt = "Hello world"
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count == prompt.unicodeScalars.count)
        #expect(accessibilityText == prompt)
    }

    // MARK: Emoji prompt truncation

    @Test func truncatesEmojiPromptAt150Scalars() {
        let emojiString = "😀"
        let emojiScalarCount = emojiString.unicodeScalars.count
        let repeatCount = 160 / emojiScalarCount
        let prompt = String(repeating: emojiString, count: repeatCount)
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count <= 150)
    }

    @Test func preservesEmojiPromptUnder150Scalars() {
        let prompt = "Hello 😀 world 🎉"
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count == prompt.unicodeScalars.count)
        #expect(accessibilityText == prompt)
    }

    // MARK: Combining character prompt truncation

    @Test func truncatesCombiningCharacterPromptAt150Scalars() {
        let baseString = "é"
        let baseScalarCount = baseString.unicodeScalars.count
        let repeatCount = 160 / baseScalarCount
        let prompt = String(repeating: baseString, count: repeatCount)
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count <= 150)
    }

    @Test func handlesMixedPromptAt150Scalars() {
        let prompt = "Hello world 你好世界 🌍 Élève combine"
        let sticker = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 512, byteCount: 10000)
        let accessibilityText = sticker.accessibilityText

        #expect(accessibilityText.unicodeScalars.count <= 150)
    }

    // MARK: Processed sticker (Preview)

    @Test func aProcessedStickerGetsTheSameDescriptionAsTheKeptSticker() {
        let prompt = String(repeating: "a", count: 160)
        let processed = ProcessedSticker(prompt: prompt, modelID: "test", quality: "medium", png: Data([0x89]), edge: 300)
        let kept = Sticker(id: UUID(), prompt: prompt, createdAt: Date(), modelID: "test", quality: "medium", pixelSize: 300, byteCount: 1)

        #expect(processed.accessibilityText.unicodeScalars.count == 150)
        #expect(processed.accessibilityText == kept.accessibilityText)
    }
}
