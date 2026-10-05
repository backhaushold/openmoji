import Foundation
import OpenMojiCore

/// The processed PNG as a temp file, for the Preview's `MSSticker` (tech spec
/// §10): `MSSticker` only loads from a file URL, and nothing is in the library
/// until Keep (FR-24). The Preview writes it when it appears and removes it
/// when it goes.
enum PreviewFile {
    /// Writes `sticker`'s PNG to a new file in `directory` and returns its URL.
    static func write(
        _ sticker: ProcessedSticker,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let url = directory.appendingPathComponent("OpenMoji-preview-\(UUID().uuidString).png")
        try sticker.png.write(to: url, options: .atomic)
        return url
    }

    /// Removes a file `write` made. Already being gone is fine.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
