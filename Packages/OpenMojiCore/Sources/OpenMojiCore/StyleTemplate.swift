import Foundation

/// Renders the tuned style template with a user-provided prompt.
/// Tech spec §9, §11. The template is inserted at {subject} with the prompt
/// trimmed and capped at 200 Characters (Swift `Character`, which counts
/// extended grapheme clusters like emoji as one).
public enum StyleTemplate {
    /// The template text from tech spec §9, unchanged from the M1 spike.
    private static let template = """
        A single emoji-style sticker of {subject}.
        Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
        bright saturated colors, soft cel shading, glossy highlight, friendly expression where a face applies.
        Composition: one subject, centered, filling about 85% of a square canvas, fully in frame, front-facing.
        Background: fully transparent. No scene, no ground, no drop shadow, no border, no frame.
        No text, letters, numbers, captions or watermarks.
        """

    /// Inserts the user prompt into the style template.
    ///
    /// - Parameters:
    ///   - userPrompt: The user's text input. Whitespace and newlines are
    ///     trimmed from both ends; the prompt is capped at 200 `Character`s
    ///     (extended grapheme clusters).
    /// - Returns: The complete prompt template with `{subject}` replaced
    ///   by the trimmed, capped prompt.
    public static func render(_ userPrompt: String) -> String {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(200))
        return template.replacingOccurrences(of: "{subject}", with: capped)
    }
}
