import Foundation
import Testing
@testable import OpenMojiCore

@Suite struct StyleTemplateTests {
    private let templateBase = """
        A single emoji-style sticker of {subject}.
        Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
        bright saturated colors, soft cel shading, glossy highlight, friendly expression where a face applies.
        Composition: one subject, centered, filling about 85% of a square canvas, fully in frame, front-facing.
        Background: fully transparent. No scene, no ground, no drop shadow, no border, no frame.
        No text, letters, numbers, captions or watermarks.
        """

    // MARK: Substitution

    @Test func substitutesPrintableText() {
        let result = StyleTemplate.render("coffee mug")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "coffee mug")
        #expect(result == expected)
    }

    @Test func substitutesSingleCharacter() {
        let result = StyleTemplate.render("a")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "a")
        #expect(result == expected)
    }

    // MARK: Trimming

    @Test func trimsLeadingWhitespace() {
        let result = StyleTemplate.render("  cat")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "cat")
        #expect(result == expected)
    }

    @Test func trimsTrailingWhitespace() {
        let result = StyleTemplate.render("cat  ")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "cat")
        #expect(result == expected)
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        let result = StyleTemplate.render("  cat  ")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "cat")
        #expect(result == expected)
    }

    @Test func trimsLeadingNewlines() {
        let result = StyleTemplate.render("\n\ndog")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "dog")
        #expect(result == expected)
    }

    @Test func trimsTrailingNewlines() {
        let result = StyleTemplate.render("dog\n\n")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "dog")
        #expect(result == expected)
    }

    @Test func trimsMixedWhitespaceAndNewlines() {
        let result = StyleTemplate.render("  \n  cat  \n  ")
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: "cat")
        #expect(result == expected)
    }

    // MARK: Character limit

    @Test func acceptsPromptAt200Characters() {
        let prompt = String(repeating: "a", count: 200)
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: prompt)
        #expect(result == expected)
    }

    @Test func capsPromptAt200Characters() {
        let prompt = String(repeating: "a", count: 250)
        let expected200 = String(repeating: "a", count: 200)
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: expected200)
        #expect(result == expected)
    }

    @Test func capsSingleEmojiAsOneCharacter() {
        // 🐸 is one extended grapheme cluster (one Character)
        let prompt = "🐸" + String(repeating: "a", count: 199)
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: prompt)
        #expect(result == expected)
    }

    @Test func capsEmojiWithModifierAsOneCharacter() {
        // 👋🏽 (waving hand with medium skin tone) is one extended grapheme cluster
        let prompt = "👋🏽" + String(repeating: "b", count: 198)
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: prompt)
        #expect(result == expected)
    }

    @Test func capsMultipleEmojisCorrectly() {
        // 🐸☕️ is two characters (each emoji is one extended grapheme cluster)
        let prompt = "🐸☕️" + String(repeating: "x", count: 198)
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: prompt)
        #expect(result == expected)
    }

    @Test func capsMultipleEmojisWhenOverLimit() {
        // Build a prompt with emojis that exceeds 200 characters
        // 🐸 (1 char) + 198 a's + ☕️ (1 char) + 10 more = 210 chars
        let prompt = "🐸" + String(repeating: "a", count: 198) + "☕️" + String(repeating: "b", count: 10)
        let expected200 = "🐸" + String(repeating: "a", count: 198) + "☕️"
        let result = StyleTemplate.render(prompt)
        let expected = templateBase.replacingOccurrences(of: "{subject}", with: expected200)
        #expect(result == expected)
    }

    // MARK: Template content

    @Test func rendersCompleteTemplateWithSubject() {
        let subject = "happy cat"
        let result = StyleTemplate.render(subject)
        #expect(result.contains("A single emoji-style sticker of happy cat."))
        #expect(result.contains("modern flat emoji illustration"))
        #expect(result.contains("bright saturated colors"))
        #expect(result.contains("fully transparent"))
        #expect(!result.contains("{subject}"))
    }

    @Test func preservesTemplateLineBreaks() {
        let result = StyleTemplate.render("test")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 6)
    }
}
