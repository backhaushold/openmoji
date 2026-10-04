import Messages
import OpenMojiCore
import SwiftUI

/// One library sticker as an `MSStickerView` (tech spec §10, ADR-0008). The
/// view gives tap-to-insert and peel-and-drag itself, so the cell does no
/// gesture handling and works with no network (FR-18, NFR-10).
///
/// A sticker's PNG never changes once kept (the file name is its id), so the
/// view is built once and `updateUIView` has nothing to do.
struct StickerCell: UIViewRepresentable {
    let sticker: Sticker
    /// The PNG in the App Group container, loaded without a copy (OQ-11).
    let url: URL

    func makeUIView(context: Context) -> MSStickerView {
        let view = MSStickerView()
        view.sticker = MSSticker.libraryEntry(sticker, at: url)
        // VoiceOver reads the sticker's description, not the file name (NFR-9).
        view.isAccessibilityElement = true
        view.accessibilityLabel = sticker.accessibilityText
        view.accessibilityTraits = .image
        return view
    }

    func updateUIView(_ view: MSStickerView, context: Context) {}
}
