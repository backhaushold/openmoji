import Foundation

extension Sticker {
    /// The prompt truncated to 150 Unicode scalars for use as an accessibility description.
    ///
    /// Derived at `MSSticker` creation time, not stored (tech spec §4, §7.3, FR-15, NFR-2).
    /// Truncates by Unicode scalars rather than grapheme clusters to be safe with Apple's 150-character limit.
    public var accessibilityText: String {
        String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(150)))
    }
}
