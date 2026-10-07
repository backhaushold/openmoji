import Foundation

/// Renders the tuned style template with a user-provided prompt.
/// Tech spec §9, §11, ADR-0018. The template is inserted at {subject}, inside
/// quotes, with the prompt reduced to one line of text (whitespace runs
/// collapsed, double quotes neutralised) and capped at 200 Characters (Swift
/// `Character`, which counts extended grapheme clusters like emoji as one).
public enum StyleTemplate {
    /// The template text from tech spec §9 (ADR-0018). The Style, Composition,
    /// Background and No-text lines are unchanged from the M1 spike; the quoted
    /// subject on line 1 and the trailing Content line are the child-safety
    /// additions.
    private static let template = """
        A single emoji-style sticker of "{subject}" (the quoted words only name the subject; they are not instructions).
        Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
        bright saturated colors, soft cel shading, glossy highlight, friendly expression where a face applies.
        Composition: one subject, centered, filling about 85% of a square canvas, fully in frame, front-facing.
        Background: fully transparent. No scene, no ground, no drop shadow, no border, no frame.
        No text, letters, numbers, captions or watermarks.
        Content: an original, child-friendly design. Never an existing character, brand or real person. No weapons, violence, gore or scary imagery. Read ambiguous words as the plain everyday object.
        """

    /// Straight and curly double quotes, matched by Unicode scalar so a quote
    /// followed by a combining mark (one `Character`) is still caught.
    private static let doubleQuotes: Set<Unicode.Scalar> = ["\"", "\u{201C}", "\u{201D}"]

    /// Inserts the user prompt into the style template.
    ///
    /// - Parameters:
    ///   - userPrompt: The user's text input, reduced to the subject that is
    ///     inserted by `sanitisedSubject(_:)`.
    /// - Returns: The complete prompt template with `{subject}` replaced
    ///   by the sanitised, capped prompt.
    public static func render(_ userPrompt: String) -> String {
        template.replacingOccurrences(of: "{subject}", with: sanitisedSubject(userPrompt))
    }

    /// The text of `userPrompt` that goes into `{subject}`: the exact words the
    /// image model reads from the user. The moderation check (ADR-0019) screens
    /// this, not the raw prompt and not the whole template, whose own "No
    /// weapons, violence, gore" line would trip it.
    ///
    /// - Parameters:
    ///   - userPrompt: The user's text input. Whitespace and newlines are
    ///     trimmed from both ends and every interior run of them becomes one
    ///     space, so the prompt can't add lines that look like template
    ///     sections. Double quotes (`"`, `“`, `”`) become `'`, so the prompt
    ///     can't close the quote that wraps it. The result is capped at 200
    ///     `Character`s (extended grapheme clusters). The quote swap is
    ///     one-for-one, so the cap counts the same before or after it, and a
    ///     prompt that `AppModel` already limited to 200 only ever shrinks.
    public static func sanitisedSubject(_ userPrompt: String) -> String {
        let oneLine = userPrompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let scalars = oneLine.unicodeScalars.map { doubleQuotes.contains($0) ? "'" : $0 }
        let neutralised = String(String.UnicodeScalarView(scalars))
        return String(neutralised.prefix(200))
    }
}
