import Foundation

extension Sticker {
    /// The prompt truncated to 150 Unicode scalars for use as an accessibility description.
    ///
    /// Derived at `MSSticker` creation time, not stored (tech spec §4, §7.3, FR-15, NFR-2).
    /// Truncates by Unicode scalars rather than grapheme clusters to be safe with Apple's 150-character limit.
    public var accessibilityText: String {
        accessibilityDescription(of: prompt)
    }
}

extension ProcessedSticker {
    /// The description the Preview's `MSSticker` gets: the same cut as the
    /// kept sticker's (`Sticker.accessibilityText`), so Preview and library
    /// read alike. It is the prompt this image was made from, even if the
    /// prompt field has been edited since.
    public var accessibilityText: String {
        accessibilityDescription(of: prompt)
    }
}

private func accessibilityDescription(of prompt: String) -> String {
    String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(150)))
}
