import Foundation
import OpenMojiCore

/// The library's search (tech spec §10): which kept stickers a typed query
/// leaves on screen. A pure function over the stickers already loaded, so it
/// needs no index, no network and no key (NFR-10).
///
/// It matches words, not meaning: "ott" finds "otter" but "otter" does not
/// find "beaver". `localizedStandardContains` is the match Finder and Mail
/// search use: case- and diacritic-insensitive, and it matches mid-word.
enum StickerSearch {
    /// `query` without the whitespace around it: what is matched, and what the
    /// no-match message quotes back.
    static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stickers whose prompt contains `query`, in the order given (newest
    /// first). An empty or whitespace-only query keeps all of them.
    static func filter(_ stickers: [Sticker], query: String) -> [Sticker] {
        let needle = trimmed(query)
        guard !needle.isEmpty else { return stickers }
        return stickers.filter { $0.prompt.localizedStandardContains(needle) }
    }
}
