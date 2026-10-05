import Foundation
import Messages
import OpenMojiCore

/// What `AppModel` needs from the library to show the grid: the stickers,
/// newest first, and where each one's PNG is (tech spec §4, §10).
///
/// The model's own seam for fakes, like `StickerGenerating`. `LibraryStore`
/// conforms to it and is wired in `MessagesViewController`.
protocol StickerLibrary: Sendable {
    /// Every kept sticker, newest first.
    func stickers() async throws -> [Sticker]
    /// The PNG for `sticker`.
    func fileURL(for sticker: Sticker) -> URL
}

/// `LibraryStore.stickers()` and `fileURL(for:)` already have the required
/// signatures.
extension LibraryStore: StickerLibrary {}

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
