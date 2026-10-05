import Foundation
import Messages
import OpenMojiCore

/// What `AppModel` needs from the library: the stickers, newest first, where
/// each one's PNG is, and Keep, the only write (tech spec §4, §10; FR-11,
/// FR-24).
///
/// The model's own seam for fakes, like `StickerGenerating`. `LibraryStore`
/// conforms to it and is wired in `MessagesViewController`.
protocol StickerLibrary: Sendable {
    /// Every kept sticker, newest first.
    func stickers() async throws -> [Sticker]
    /// Writes `processed` to the library, which then lists it first. Takes a
    /// `ProcessedSticker`, so a failed generation can't reach it.
    func keep(_ processed: ProcessedSticker) async throws
    /// The PNG for `sticker`.
    func fileURL(for sticker: Sticker) -> URL
}

/// `LibraryStore.stickers()` and `fileURL(for:)` already have the required
/// signatures. Its own `keep(_:at:)` takes the date, which Keep sets to now.
extension LibraryStore: StickerLibrary {
    func keep(_ processed: ProcessedSticker) async throws {
        try keep(processed, at: Date())
    }
}

extension MSSticker {
    /// A library sticker, loaded straight from its App Group file with no temp
    /// copy (OQ-11). Its description, the prompt cut to 150 Unicode scalars, is
    /// what VoiceOver reads (FR-15, NFR-9). `MSSticker` doesn't check the file
    /// when it is created (a missing or invalid one gives a sticker with no
    /// image, seen on the simulator), so a bad entry shows as a blank cell, and
    /// nil is only for an error the initializer does throw.
    static func libraryEntry(_ sticker: Sticker, at url: URL) -> MSSticker? {
        try? MSSticker(contentsOfFileURL: url, localizedDescription: sticker.accessibilityText)
    }
}
